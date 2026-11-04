import 'models.dart';

class DayStats {
  DayStats({
    required this.day,
    required this.sessions,
    required this.worked,
    required this.target,
    required this.absence,
  });

  final DateTime day;
  final List<WorkSession> sessions;
  final Duration worked;

  /// Soll-Zeit des Tages (0 an freien Tagen).
  final Duration target;

  /// Abwesenheit an diesem Tag (Krank/Urlaub/…), falls vorhanden.
  final Absence? absence;

  bool get isWorkday => target > Duration.zero;

  /// Gutgeschriebene Zeit durch Abwesenheit: Abwesenheit an einem Arbeitstag
  /// zählt wie ein voll gearbeiteter Tag.
  Duration get credited =>
      absence != null && isWorkday ? target : Duration.zero;

  /// Differenz zum Soll: positiv = Überstunden, negativ = Minusstunden.
  Duration get diff => worked + credited - target;

  /// Pausen = Lücken zwischen zwei Arbeitszeiten am selben Tag.
  Duration get breaks {
    var total = Duration.zero;
    for (var i = 1; i < sessions.length; i++) {
      final prevEnd = sessions[i - 1].end;
      if (prevEnd == null) continue;
      final gap = sessions[i].start.difference(prevEnd);
      if (gap > Duration.zero) total += gap;
    }
    return total;
  }
}

/// Berechnet Tageswerte und das Stundenkonto.
class BalanceCalculator {
  BalanceCalculator(this.data, this.now) {
    for (final s in data.sessions) {
      _byDay.putIfAbsent(dayKey(s.start), () => []).add(s);
    }
    for (final list in _byDay.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
  }

  final AppData data;
  final DateTime now;
  final Map<String, List<WorkSession>> _byDay = {};

  Settings get settings => data.settings;

  Duration targetFor(DateTime day) => settings.workdays.contains(day.weekday)
      ? Duration(minutes: settings.dailyTargetMinutes)
      : Duration.zero;

  Absence? absenceFor(DateTime day) {
    for (final a in data.absences) {
      if (a.covers(day)) return a;
    }
    return null;
  }

  List<WorkSession> sessionsFor(DateTime day) =>
      List.unmodifiable(_byDay[dayKey(day)] ?? const <WorkSession>[]);

  DayStats statsFor(DateTime day) {
    final d = dayOf(day);
    final sessions = sessionsFor(d);
    final worked =
        sessions.fold(Duration.zero, (sum, s) => sum + s.durationAt(now));
    return DayStats(
      day: d,
      sessions: sessions,
      worked: worked,
      target: targetFor(d),
      absence: absenceFor(d),
    );
  }

  /// Stundenkonto inkl. Startwert.
  ///
  /// Vergangene Tage zählen vollständig (nicht erfasste Arbeitstage gehen mit
  /// den Tagesstunden ins Minus). Der heutige Tag zählt erst nach Tagesende
  /// negativ – Überstunden von heute werden aber sofort gutgeschrieben.
  Duration balance() {
    var total = Duration(minutes: settings.startBalanceMinutes);
    final today = dayOf(now);
    var d = settings.startDate;
    while (d.isBefore(today)) {
      total += statsFor(d).diff;
      d = DateTime(d.year, d.month, d.day + 1);
    }
    if (!settings.startDate.isAfter(today)) {
      final t = statsFor(today).diff;
      if (t > Duration.zero) total += t;
    }
    return total;
  }

  /// Summe der Differenzen für den Zeitraum [from] bis [to] (inklusive),
  /// begrenzt auf Tage ab dem Erfassungsbeginn und bis heute.
  Duration diffBetween(DateTime from, DateTime to) {
    var total = Duration.zero;
    final today = dayOf(now);
    var d = dayOf(from).isBefore(settings.startDate)
        ? settings.startDate
        : dayOf(from);
    final last = dayOf(to).isAfter(today) ? today : dayOf(to);
    while (!d.isAfter(last)) {
      final diff = statsFor(d).diff;
      if (d == today) {
        if (diff > Duration.zero) total += diff;
      } else {
        total += diff;
      }
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return total;
  }
}
