import 'models.dart';
import 'reminder.dart';

/// Zeiterfassung beim Programmstart automatisch beginnen (Desktop).
///
/// Gilt nur für dieses Gerät – wie der Autostart mit dem System – und wird
/// daher weder synchronisiert noch exportiert.
enum AutoTrack {
  /// Nicht automatisch starten (Standard).
  off,

  /// Nur an Arbeitstagen ohne Feiertag/Abwesenheit starten.
  workdays,

  /// Bei jedem Programmstart starten.
  always;

  static AutoTrack byName(String? name) =>
      values.where((v) => v.name == name).firstOrNull ?? off;
}

/// Soll die Zeiterfassung beim Programmstart um [now] beginnen?
///
/// Nie, wenn sie schon läuft. An Arbeitstagen nicht erneut, wenn heute
/// bereits „Feierabend“ gewählt wurde ([stoppedToday]).
bool shouldAutoTrack(AutoTrack mode, AppData data, DateTime now,
    {bool stoppedToday = false}) {
  if (data.running != null) return false;
  switch (mode) {
    case AutoTrack.off:
      return false;
    case AutoTrack.always:
      return true;
    case AutoTrack.workdays:
      return !stoppedToday && isWorkday(data, now);
  }
}
