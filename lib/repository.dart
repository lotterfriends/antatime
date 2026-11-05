import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

import 'models.dart';

/// Persistenz über SharedPreferences (Android/iOS nativ, im Browser
/// localStorage). Ohne Cache, damit Änderungen aus dem Hintergrund
/// (Benachrichtigungs-Aktionen) sofort sichtbar sind.
///
/// Auf Android liegen die Daten in der SharedPreferences-Datei „antatime“,
/// damit die native Benachrichtigung (TrackingStore.kt) sie direkt lesen und
/// ändern kann.
class Repository {
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

  Future<AppData> load() async {
    await _migrate();
    final sessionsRaw = await _prefs.getString(_kSessions);
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

  Future<void> saveSessions(List<WorkSession> sessions) => _prefs.setString(
      _kSessions, jsonEncode(sessions.map((s) => s.toJson()).toList()));

  Future<void> saveAbsences(List<Absence> absences) => _prefs.setString(
      _kAbsences, jsonEncode(absences.map((a) => a.toJson()).toList()));

  Future<void> saveSettings(Settings settings) =>
      _prefs.setString(_kSettings, jsonEncode(settings.toJson()));

  Future<void> saveAll(AppData data) async {
    await saveSessions(data.sessions);
    await saveAbsences(data.absences);
    await saveSettings(data.settings);
  }

  /// Nach einem Start soll die Benachrichtigung wieder erscheinen.
  Future<void> clearStopped() => _prefs.remove(_kStoppedDay);

  /// Start/Pause umschalten. Wird von App und Benachrichtigung genutzt.
  /// Gibt `true` zurück, wenn danach eine Arbeitszeit läuft.
  static bool toggle(AppData data, DateTime now) {
    final running = data.running;
    if (running != null) {
      running.end = now;
      return false;
    }
    data.sessions.add(WorkSession(id: newId(), start: now));
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
