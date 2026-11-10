import 'balance.dart';
import 'models.dart';

/// Wurde die Zeiterfassung an [day] schon gestartet (oder läuft sie noch)?
bool startedOn(AppData data, DateTime day) {
  final d = dayOf(day);
  for (final s in data.sessions) {
    if (s.isRunning || dayOf(s.start) == d) return true;
  }
  return false;
}

/// Nächste Zeitpunkte, zu denen an den Start der Zeiterfassung erinnert
/// wird: an Arbeitstagen ohne Feiertag/Abwesenheit um
/// [Settings.reminderMinutes], heute nur, falls noch nicht gestartet.
///
/// Betrachtet die nächsten [days] Tage ab heute (iOS erlaubt höchstens 64
/// geplante Benachrichtigungen; beim nächsten Öffnen der App wird neu
/// geplant).
List<DateTime> reminderTimes(AppData data, DateTime now, {int days = 30}) {
  final minutes = data.settings.reminderMinutes;
  if (minutes == null) return const [];
  final calc = BalanceCalculator(data, now);
  final today = dayOf(now);
  final result = <DateTime>[];
  for (var i = 0; i < days; i++) {
    final day = DateTime(today.year, today.month, today.day + i);
    final at = DateTime(day.year, day.month, day.day, minutes ~/ 60,
        minutes % 60);
    if (!at.isAfter(now)) continue;
    if (!data.settings.workdays.contains(day.weekday)) continue;
    if (day.isBefore(data.settings.startDate)) continue;
    if (calc.absenceFor(day) != null) continue;
    if (i == 0 && startedOn(data, day)) continue;
    result.add(at);
  }
  return result;
}
