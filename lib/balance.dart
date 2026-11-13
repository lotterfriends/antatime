import 'holidays.dart';
import 'models.dart';

class DayStats {
  DayStats({
    required this.day,
    required this.sessions,
    required this.worked,
    required this.target,
    required this.absence,
    this.halfHoliday,
    this.absenceWorkFactor = 1,
  });

  final DateTime day;
  final List<WorkSession> sessions;
  final Duration worked;

  /// Soll-Zeit des Tages (0 an freien Tagen).
  final Duration target;

  /// Abwesenheit an diesem Tag (Krank/Urlaub/…), falls vorhanden.
  final Absence? absence;

  /// Halber Feiertag an diesem Tag (Soll ist dann bereits halbiert).
  final Absence? halfHoliday;

  /// Faktor für Arbeit an Abwesenheitstagen (Einstellung).
  final double absenceWorkFactor;

  /// Faktor, mit dem die Arbeitszeit dieses Tages ins Konto eingeht:
  /// an Feiertagen, im Urlaub und bei anderer Abwesenheit der eingestellte
  /// Faktor, sonst (auch bei Krankheit) 1.
  double get workFactor =>
      absence != null && absence!.type != AbsenceType.sick
          ? absenceWorkFactor
          : 1;

  /// Zusätzlich gutgeschriebene Zeit durch den Faktor (0 bei Faktor 1).
  Duration get bonus => Duration(
      microseconds: (worked.inMicroseconds * (workFactor - 1)).round());

  bool get isWorkday => target > Duration.zero;

  /// Gutgeschriebene Zeit durch Abwesenheit: Abwesenheit an einem Arbeitstag
  /// zählt wie ein voll gearbeiteter Tag.
  Duration get credited =>
      absence != null && isWorkday ? target : Duration.zero;

  /// Differenz zum Soll: positiv = Überstunden, negativ = Minusstunden.
  /// Arbeit an Abwesenheitstagen zählt voll (mal Faktor) als Überstunden,
  /// da das Soll bereits durch die Gutschrift erfüllt ist.
  Duration get diff => worked + bonus + credited - target;

  /// Pausen = Lücken zwischen zwei Arbeitszeiten am selben Tag
  /// (kürzer als [minBreak] zählen nicht).
  Duration get breaks {
    var total = Duration.zero;
    for (var i = 1; i < sessions.length; i++) {
      final prevEnd = sessions[i - 1].end;
      if (prevEnd == null) continue;
      final gap = sessions[i].start.difference(prevEnd);
      if (gap >= minBreak) total += gap;
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
  final Map<int, Map<String, Absence>> _holidaysByYear = {};
  final Map<int, Map<String, Absence>> _christmasByYear = {};

  Settings get settings => data.settings;

  /// Soll-Zeit des Tages; an halben Feiertagen die Hälfte.
  Duration targetFor(DateTime day) {
    if (!settings.workdays.contains(day.weekday)) return Duration.zero;
    final full = Duration(minutes: settings.dailyTargetMinutes);
    return halfHolidayFor(day) != null ? full ~/ 2 : full;
  }

  /// Halbe Feiertage (Heiligabend/Silvester) des Jahres als (nicht
  /// gespeicherte) Abwesenheiten. Ist eingestellt, dass diese Tage ganz frei
  /// sind, zählen sie stattdessen als ganze Feiertage (siehe [holidaysIn]).
  List<Absence> halfHolidaysIn(int year) =>
      _halfHolidayMap(year).values.toList(growable: false);

  Map<String, Absence> _halfHolidayMap(int year) {
    if (!settings.halfHolidays) return const {};
    return _christmasMap(year);
  }

  /// Heiligabend und Silvester – halb oder ganz frei je nach Einstellung.
  Map<String, Absence> _christmasMap(int year) =>
      _christmasByYear.putIfAbsent(year, () => {
          for (final h in halfHolidaysFor(year))
            dayKey(h.date): Absence(
              id: 'christmas-${dayKey(h.date)}',
              type: AbsenceType.holiday,
              from: h.date,
              to: h.date,
              note: h.name,
              half: settings.halfHolidays,
            ),
        });

  /// Halber Feiertag am [day], falls vorhanden.
  Absence? halfHolidayFor(DateTime day) =>
      _halfHolidayMap(day.year)[dayKey(day)];

  /// Arbeitstage, die [a] belegt: halbe Feiertage zählen halb, ganze
  /// Feiertage gar nicht (außer [a] ist selbst ein Feiertag).
  double workdaysOf(Absence a) {
    var n = 0.0;
    for (var d = a.from;
        !d.isAfter(a.to);
        d = DateTime(d.year, d.month, d.day + 1)) {
      if (!settings.workdays.contains(d.weekday)) continue;
      if (a.isHoliday) {
        n += a.half ? 0.5 : 1;
      } else if (holidayFor(d) == null) {
        n += halfHolidayFor(d) != null ? 0.5 : 1;
      }
    }
    return n;
  }

  /// Ganze Feiertage des Jahres als (nicht gespeicherte) Abwesenheiten:
  /// gesetzliche Feiertage im gewählten Bundesland sowie Heiligabend und
  /// Silvester, falls diese ganz frei sind.
  List<Absence> holidaysIn(int year) =>
      _holidayMap(year).values.toList(growable: false);

  Map<String, Absence> _holidayMap(int year) {
    final state = settings.federalState;
    return _holidaysByYear.putIfAbsent(year, () => {
          if (state != null)
            for (final h in holidaysFor(state, year))
              dayKey(h.date): Absence(
                id: 'holiday-${dayKey(h.date)}',
                type: AbsenceType.holiday,
                from: h.date,
                to: h.date,
                note: h.name,
              ),
          if (!settings.halfHolidays) ..._christmasMap(year),
        });
  }

  Absence? holidayFor(DateTime day) => _holidayMap(day.year)[dayKey(day)];

  /// Abwesenheit des Tages; ein Feiertag hat Vorrang (z. B. im Urlaub).
  Absence? absenceFor(DateTime day) {
    final holiday = holidayFor(day);
    if (holiday != null) return holiday;
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
      halfHoliday: halfHolidayFor(d),
      absenceWorkFactor: settings.absenceWorkFactor,
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
