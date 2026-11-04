import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persistenz über SharedPreferences (Android/iOS nativ, im Browser
/// localStorage). Ohne Cache, damit Änderungen aus dem Hintergrund-Isolate
/// (Benachrichtigungs-Aktionen) sofort sichtbar sind.
class Repository {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  static const _kSessions = 'sessions';
  static const _kAbsences = 'absences';
  static const _kSettings = 'settings';

  Future<AppData> load() async {
    final sessionsRaw = await _prefs.getString(_kSessions);
    final absencesRaw = await _prefs.getString(_kAbsences);
    final settingsRaw = await _prefs.getString(_kSettings);

    final sessions = sessionsRaw == null
        ? <WorkSession>[]
        : (jsonDecode(sessionsRaw) as List)
            .map((e) => WorkSession.fromJson(e as Map<String, dynamic>))
            .toList();
    final absences = absencesRaw == null
        ? <Absence>[]
        : (jsonDecode(absencesRaw) as List)
            .map((e) => Absence.fromJson(e as Map<String, dynamic>))
            .toList();
    final settings = settingsRaw == null
        ? Settings()
        : Settings.fromJson(jsonDecode(settingsRaw) as Map<String, dynamic>);

    if (settingsRaw == null) {
      await saveSettings(settings);
    }
    return AppData(sessions: sessions, absences: absences, settings: settings);
  }

  Future<void> saveSessions(List<WorkSession> sessions) => _prefs.setString(
      _kSessions, jsonEncode(sessions.map((s) => s.toJson()).toList()));

  Future<void> saveAbsences(List<Absence> absences) => _prefs.setString(
      _kAbsences, jsonEncode(absences.map((a) => a.toJson()).toList()));

  Future<void> saveSettings(Settings settings) =>
      _prefs.setString(_kSettings, jsonEncode(settings.toJson()));

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
}
