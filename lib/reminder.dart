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
    if (!_remindOn(calc, day)) continue;
    if (i == 0 && startedOn(data, day)) continue;
    result.add(at);
  }
  return result;
}

/// Ist [day] ein Arbeitstag ab Erfassungsbeginn ohne Feiertag/Abwesenheit?
bool isWorkday(AppData data, DateTime day) =>
    _remindOn(BalanceCalculator(data, day), dayOf(day));

/// Arbeitstag ab Erfassungsbeginn ohne Feiertag/Abwesenheit?
bool _remindOn(BalanceCalculator calc, DateTime day) =>
    calc.settings.workdays.contains(day.weekday) &&
    !day.isBefore(calc.settings.startDate) &&
    calc.absenceFor(day) == null;

/// Soll-Zeiten der nächsten [days] Tage ab heute, an denen beim Erreichen
/// der Tagesstunden benachrichtigt wird (leer, wenn ausgeschaltet).
///
/// Für Android: Die native Seite plant damit selbst, auch wenn die
/// Arbeitszeit über die Benachrichtigung bei geschlossener App gestartet
/// wird.
Map<DateTime, Duration> targetReminderDays(AppData data, DateTime now,
    {int days = 30}) {
  if (!data.settings.targetReminder) return const {};
  final calc = BalanceCalculator(data, now);
  final today = dayOf(now);
  final result = <DateTime, Duration>{};
  for (var i = 0; i < days; i++) {
    final day = DateTime(today.year, today.month, today.day + i);
    if (_remindOn(calc, day)) result[day] = calc.targetFor(day);
  }
  return result;
}

/// Zeitpunkt, zu dem heute die Tagesstunden erreicht sind, wenn die
/// laufende Arbeitszeit weiterläuft – `null`, wenn ausgeschaltet, keine
/// Arbeitszeit läuft, heute kein Arbeitstag ist oder das Soll schon
/// erreicht ist.
DateTime? targetReachedAt(AppData data, DateTime now) {
  if (!data.settings.targetReminder || data.running == null) return null;
  final calc = BalanceCalculator(data, now);
  if (!_remindOn(calc, dayOf(now))) return null;
  final stats = calc.statsFor(now);
  if (stats.target <= Duration.zero || stats.worked >= stats.target) {
    return null;
  }
  return now.add(stats.target - stats.worked);
}
