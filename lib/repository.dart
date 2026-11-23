import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

import 'auto_track.dart';
import 'models.dart';
import 'tray_icon_style.dart';
import 'sync/cross_tab_lock.dart';
import 'sync/sync_records.dart';
import 'sync/sync_service.dart';

/// Persistenz über SharedPreferences (Android/iOS nativ, im Browser
/// localStorage). Ohne Cache, damit Änderungen aus dem Hintergrund
/// (Benachrichtigungs-Aktionen) sofort sichtbar sind.
///
/// Auf Android liegen die Daten in der SharedPreferences-Datei „antatime“,
/// damit die native Benachrichtigung (TrackingStore.kt) sie direkt lesen und
/// ändern kann.
class Repository implements SyncStore {
  Repository() : _prefs = SharedPreferencesAsync(options: _options);

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static SharedPreferencesOptions get _options => _isAndroid
      ? const SharedPreferencesAsyncAndroidOptions(
          backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
          originalSharedPreferencesOptions:
              AndroidSharedPreferencesStoreOptions(fileName: 'antatime'),
        )
      : const SharedPreferencesOptions();

  final SharedPreferencesAsync _prefs;

  static const _kSessions = 'sessions';
  static const _kAbsences = 'absences';
  static const _kSettings = 'settings';

  /// Tag (yyyy-MM-dd), an dem in der Benachrichtigung „Feierabend“ gedrückt
  /// wurde. Bis zum nächsten Start bleibt die Benachrichtigung dann aus.
  static const _kStoppedDay = 'notificationStoppedDay';

  /// Zeiterfassung beim Programmstart beginnen (nur dieses Gerät, siehe
  /// [AutoTrack]).
  static const _kAutoTrack = 'autoTrack';

  /// Spätester automatischer Start in Minuten nach Mitternacht (nur dieses
  /// Gerät, siehe [shouldAutoTrack]); fehlt = ohne Begrenzung.
  static const _kAutoTrackUntil = 'autoTrackUntil';

  /// Darstellung des Tray-Symbols (nur dieses Gerät, siehe [TrayIconStyle]).
  static const _kTrayIconStyle = 'trayIconStyle';

  /// Sync-Zustand (Code, Server, Snapshot), siehe lib/sync/.
  static const _kSync = 'sync';

  Future<void> _lock = Future.value();

  /// Führt [action] exklusiv aus (App-Änderungen und Sync nacheinander,
  /// im Browser auch über mehrere Tabs hinweg).
  @override
  Future<T> exclusive<T>(Future<T> Function() action) {
    final result =
        _lock.then((_) => crossTabLock('antatime-data', action));
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<String?> loadSyncState() => _prefs.getString(_kSync);

  @override
  Future<void> saveSyncState(String? json) =>
      json == null ? _prefs.remove(_kSync) : _prefs.setString(_kSync, json);

  static const exportFormat = 'antatime-backup';
  static const exportVersion = 1;

  bool _migrated = false;

  /// Übernimmt Daten aus dem früheren Speicherort (DataStore) einmalig.
  Future<void> _migrate() async {
    if (_migrated || !_isAndroid) return;
    _migrated = true;
    if (await _prefs.containsKey(_kSettings)) return;
    final old = SharedPreferencesAsync();
    for (final key in [_kSessions, _kAbsences, _kSettings]) {
      final v = await old.getString(key);
      if (v != null) await _prefs.setString(key, v);
    }
  }

  @override
  Future<AppData> load() async {
    await _migrate();
    final sessionsRaw = await _prefs.getString(_kSessions);
    _loadedSessions = sessionsRaw;
    final absencesRaw = await _prefs.getString(_kAbsences);
    final settingsRaw = await _prefs.getString(_kSettings);

    final data = AppData(
      sessions: sessionsRaw == null ? [] : _sessionsFrom(jsonDecode(sessionsRaw)),
      absences: absencesRaw == null ? [] : _absencesFrom(jsonDecode(absencesRaw)),
      settings: settingsRaw == null
          ? Settings()
          : Settings.fromJson(jsonDecode(settingsRaw) as Map<String, dynamic>),
    );
    if (settingsRaw == null) await saveSettings(data.settings);
    return data;
  }

  static List<WorkSession> _sessionsFrom(Object? json) => (json as List)
      .map((e) => WorkSession.fromJson(e as Map<String, dynamic>))
      .toList();

  static List<Absence> _absencesFrom(Object? json) => (json as List)
      .map((e) => Absence.fromJson(e as Map<String, dynamic>))
      .toList();

  /// Arbeitszeiten, wie sie zuletzt geladen bzw. gespeichert wurden (roh).
  String? _loadedSessions;

  static const _native = MethodChannel('antatime/notification');

  static String _encodeSessions(List<WorkSession> sessions) =>
      jsonEncode(sessions.map((s) => s.toJson()).toList());

  /// Speichert die Arbeitszeiten.
  ///
  /// Auf Android kann die native Benachrichtigung (TrackingStore.kt) sie
  /// jederzeit ändern – an [exclusive] vorbei. Deshalb wird dort nur
  /// gespeichert, wenn noch der geladene Stand vorliegt (atomar im nativen
  /// Teil). Sonst werden beide Änderungen zusammengeführt (siehe
  /// [rebaseSessions]) und erneut versucht.
  Future<void> saveSessions(List<WorkSession> sessions) async {
    if (!_isAndroid) {
      final raw = _encodeSessions(sessions);
      await _prefs.setString(_kSessions, raw);
      _loadedSessions = raw;
      return;
    }
    var ours = sessions;
    for (var attempt = 0; attempt < 5; attempt++) {
      final raw = _encodeSessions(ours);
      final bool? ok;
      try {
        ok = await _native
            .invokeMethod<bool>('casSessions', [_loadedSessions, raw]);
      } on MissingPluginException {
        // Ohne Activity (kein Kanal) gibt es auch keine native Aktion.
        await _prefs.setString(_kSessions, raw);
        _loadedSessions = raw;
        return;
      }
      if (ok == true) {
        _loadedSessions = raw;
        return;
      }
      final current = await _prefs.getString(_kSessions);
      ours = rebaseSessions(
        base: _parseSessions(_loadedSessions),
        theirs: _parseSessions(current),
        ours: ours,
      );
      _loadedSessions = current;
    }
    throw StateError('Arbeitszeiten konnten nicht gespeichert werden.');
  }

  /// Zeitpunkte, zu denen die Android-Benachrichtigung Arbeitszeiten
  /// geändert hat (ID → ms); werden dabei gelöscht. Siehe
  /// [SyncState.diffLocal].
  Future<Map<String, int>> takeNativeChanges() async {
    if (!_isAndroid) return const {};
    try {
      final m = await _native.invokeMapMethod<String, Object?>(
          'takeNativeChanges');
      return {
        for (final e in (m ?? const {}).entries)
          if (e.value is num) e.key: (e.value as num).toInt(),
      };
    } on MissingPluginException {
      return const {};
    }
  }

  static List<WorkSession> _parseSessions(String? raw) =>
      raw == null ? [] : _sessionsFrom(jsonDecode(raw));

  /// Führt eigene Änderungen ([ours], ausgehend von [base]) mit denen eines
  /// anderen Schreibers ([theirs], z. B. Start/Pause in der Benachrichtigung)
  /// zusammen – je Arbeitszeit. Haben beide dieselbe geändert, gewinnt
  /// [theirs]: Das ist die jüngste Aktion des Nutzers.
  static List<WorkSession> rebaseSessions({
    required List<WorkSession> base,
    required List<WorkSession> theirs,
    required List<WorkSession> ours,
  }) {
    Map<String, String> byId(List<WorkSession> l) =>
        {for (final s in l) s.id: jsonEncode(s.toJson())};
    final b = byId(base), t = byId(theirs), o = byId(ours);
    final result = <WorkSession>[];
    for (final id in {...b.keys, ...t.keys, ...o.keys}) {
      final pick = o[id] == b[id] ? t[id] : (t[id] == b[id] ? o[id] : t[id]);
      if (pick != null) {
        result.add(
            WorkSession.fromJson(jsonDecode(pick) as Map<String, dynamic>));
      }
    }
    return result..sort((a, b) => a.start.compareTo(b.start));
  }

  Future<void> saveAbsences(List<Absence> absences) => _prefs.setString(
      _kAbsences, jsonEncode(absences.map((a) => a.toJson()).toList()));

  Future<void> saveSettings(Settings settings) =>
      _prefs.setString(_kSettings, jsonEncode(settings.toJson()));

  @override
  Future<void> saveAll(AppData data) async {
    await saveSessions(data.sessions);
    await saveAbsences(data.absences);
    await saveSettings(data.settings);
  }

  Future<AutoTrack> loadAutoTrack() async =>
      AutoTrack.byName(await _prefs.getString(_kAutoTrack));

  Future<void> saveAutoTrack(AutoTrack mode) => mode == AutoTrack.off
      ? _prefs.remove(_kAutoTrack)
      : _prefs.setString(_kAutoTrack, mode.name);

  Future<int?> loadAutoTrackUntil() async {
    final v = int.tryParse(await _prefs.getString(_kAutoTrackUntil) ?? '');
    return v != null && v >= 0 && v < 24 * 60 ? v : null;
  }

  Future<void> saveAutoTrackUntil(int? minutes) => minutes == null
      ? _prefs.remove(_kAutoTrackUntil)
      : _prefs.setString(_kAutoTrackUntil, '$minutes');

  Future<TrayIconStyle> loadTrayIconStyle() async =>
      TrayIconStyle.byName(await _prefs.getString(_kTrayIconStyle));

  Future<void> saveTrayIconStyle(TrayIconStyle style) =>
      style == TrayIconStyle.color
          ? _prefs.remove(_kTrayIconStyle)
          : _prefs.setString(_kTrayIconStyle, style.name);

  /// Nach einem Start soll die Benachrichtigung wieder erscheinen.
  Future<void> clearStopped() => _prefs.remove(_kStoppedDay);

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// „Feierabend“ für [now] merken (wie TrackingStore.stop auf Android).
  Future<void> markStopped(DateTime now) =>
      _prefs.setString(_kStoppedDay, _dayKey(now));

  /// Wurde heute „Feierabend“ gewählt (und seitdem nicht wieder gestartet)?
  Future<bool> stoppedOn(DateTime now) async =>
      await _prefs.getString(_kStoppedDay) == _dayKey(now);

  /// Start/Pause umschalten. Wird von App und Benachrichtigung genutzt.
  /// Gibt `true` zurück, wenn danach eine Arbeitszeit läuft.
  static bool toggle(AppData data, DateTime now) {
    final running = data.running;
    if (running != null) {
      running.end = now;
      return false;
    }
    // Pausen unter einer Minute ignorieren: den zuletzt beendeten Abschnitt
    // einfach fortsetzen statt einen neuen zu beginnen.
    WorkSession? last;
    for (final s in data.sessions) {
      if (s.end != null && (last == null || s.end!.isAfter(last.end!))) {
        last = s;
      }
    }
    if (last != null) {
      final gap = now.difference(last.end!);
      if (!gap.isNegative && gap < minBreak) {
        last.end = null;
        return true;
      }
    }
    data.sessions.add(WorkSession(id: newId(), start: now));
    return true;
  }

  /// Löscht die Pause zwischen [beforeId] und [afterId]: Der frühere
  /// Abschnitt reicht danach bis zum Ende des späteren (läuft also weiter,
  /// falls dieser noch läuft), der spätere wird entfernt. Notizen werden
  /// zusammengeführt. Gibt `false` zurück, wenn einer fehlt.
  static bool mergeSessions(AppData data, String beforeId, String afterId) {
    final before = data.sessions.where((s) => s.id == beforeId).firstOrNull;
    final after = data.sessions.where((s) => s.id == afterId).firstOrNull;
    if (before == null || after == null || before == after) return false;
    before.end = after.end;
    final notes = [before.note, after.note]
        .where((n) => n != null && n.trim().isNotEmpty)
        .toList();
    before.note = notes.isEmpty ? null : notes.join('\n');
    data.sessions.remove(after);
    return true;
  }

  /// Alle Daten und Einstellungen als JSON-Text (Export).
  static String exportJson(AppData data, {DateTime? now}) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': exportFormat,
        'version': exportVersion,
        'exportedAt': (now ?? DateTime.now()).toIso8601String(),
        'settings': data.settings.toJson(),
        'sessions': data.sessions.map((s) => s.toJson()).toList(),
        'absences': data.absences.map((a) => a.toJson()).toList(),
      });

  /// Liest einen Export. Wirft [FormatException] bei ungültigem Inhalt.
  static AppData importJson(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Die Datei ist kein gültiges JSON.');
    }
    if (json is! Map<String, dynamic> || json['format'] != exportFormat) {
      throw const FormatException('Die Datei ist kein AnTaTime-Export.');
    }
    final version = json['version'];
    if (version is! int || version > exportVersion) {
      throw const FormatException(
          'Der Export stammt aus einer neueren App-Version.');
    }
    try {
      final settings = json['settings'];
      final data = AppData(
        sessions: _sessionsFrom(json['sessions'] ?? const []),
        absences: _absencesFrom(json['absences'] ?? const []),
        settings: settings == null
            ? Settings()
            : Settings.fromJson(settings as Map<String, dynamic>),
      );
      data.sessions.sort((a, b) => a.start.compareTo(b.start));
      data.absences.sort((a, b) => b.from.compareTo(a.from));
      return data;
    } catch (_) {
      throw const FormatException('Die Datei enthält ungültige Einträge.');
    }
  }
}
