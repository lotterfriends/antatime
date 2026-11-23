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
    this.lateWorked = Duration.zero,
    this.lateWorkMinutes,
    this.lateWorkFactor = 1,
    this.stackWorkFactors = false,
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

  /// Arbeitszeit nach [lateWorkMinutes] (ohne Pausen).
  final Duration lateWorked;

  /// Uhrzeit (Minuten nach Mitternacht), ab der der Spätarbeits-Faktor gilt
  /// (`null` = aus).
  final int? lateWorkMinutes;

  /// Faktor für Arbeit nach [lateWorkMinutes] (Einstellung).
  final double lateWorkFactor;

  /// Zuschläge beider Faktoren addieren statt nur den höheren zu nehmen.
  final bool stackWorkFactors;

  /// Faktor, mit dem die Arbeitszeit dieses Tages wegen einer Abwesenheit
  /// ins Konto eingeht: an Feiertagen, im Urlaub und bei anderer
  /// Abwesenheit der eingestellte Faktor, sonst (auch bei Krankheit) 1.
  double get absenceFactor =>
      absence != null && absence!.type != AbsenceType.sick
          ? absenceWorkFactor
          : 1;

  /// Faktor für die Arbeit nach [lateWorkMinutes] (1 = aus).
  double get lateFactor => lateWorkMinutes == null ? 1 : lateWorkFactor;

  /// Zuschlag durch den Abwesenheits-Faktor (0 bei Faktor 1).
  /// Pausen sind keine Arbeitszeit und bekommen keinen Zuschlag.
  Duration get absenceBonus => Duration(
      microseconds: (worked.inMicroseconds * (absenceFactor - 1)).round());

  /// Zuschlag durch den Spätarbeits-Faktor (0 bei Faktor 1). Gilt an dem
  /// Tag auch ein Abwesenheits-Faktor, addieren sich die Zuschläge nur bei
  /// [stackWorkFactors]; sonst zählt die Abendarbeit mit dem höheren Faktor
  /// (der Abend-Zuschlag ist dann nur der Teil über dem Abwesenheits-Faktor).
  Duration get lateBonus {
    final extra = stackWorkFactors
        ? lateFactor - 1
        : (lateFactor > absenceFactor ? lateFactor : absenceFactor) -
            absenceFactor;
    return Duration(
        microseconds: (lateWorked.inMicroseconds * extra).round());
  }

  /// Zusätzlich gutgeschriebene Zeit durch die Faktoren.
  Duration get bonus => absenceBonus + lateBonus;

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
  /// Feiertage je Jahr und Einstellungs-Zeitraum (`'$year/$period'`).
  final Map<String, Map<String, Absence>> _holidaysByYear = {};
  final Map<String, Map<String, Absence>> _christmasByYear = {};
  final Map<int, Settings> _periodSettings = {};

  /// Aktuelle Einstellungen.
  Settings get settings => data.settings;

  /// Einstellungen, die am [day] galten (siehe [Settings.periods]).
  Settings settingsFor(DateTime day) =>
      _settingsOf(settings.periodIndexFor(day));

  Settings _settingsOf(int period) =>
      _periodSettings.putIfAbsent(period, () => settings.forPeriod(period));

  /// Zeiträume, die Tage im Jahr [year] betreffen (`-1` = aktuelle).
  Iterable<int> _periodsIn(int year) sync* {
    final periods = settings.periods;
    final first = DateTime(year), last = DateTime(year, 12, 31);
    for (var i = 0; i < periods.length; i++) {
      final from = i == 0 ? null : periods[i - 1].until;
      if (!periods[i].until.isBefore(first) &&
          (from == null || from.isBefore(last))) {
        yield i;
      }
    }
    if (periods.isEmpty || periods.last.until.isBefore(last)) yield -1;
  }

  /// Soll-Zeit des Tages; an halben Feiertagen die Hälfte.
  Duration targetFor(DateTime day) {
    final s = settingsFor(day);
    if (!s.workdays.contains(day.weekday)) return Duration.zero;
    final full = Duration(minutes: s.dailyTargetMinutes);
    return halfHolidayFor(day) != null ? full ~/ 2 : full;
  }

  /// Halbe Feiertage (Heiligabend/Silvester) des Jahres als (nicht
  /// gespeicherte) Abwesenheiten. Ist eingestellt, dass diese Tage ganz frei
  /// sind, zählen sie stattdessen als ganze Feiertage (siehe [holidaysIn]).
  List<Absence> halfHolidaysIn(int year) => _inYear(year, _halfHolidayMap);

  /// Einträge der Jahres-Tabellen aller Zeiträume, jeweils nur für die Tage,
  /// an denen der Zeitraum galt.
  List<Absence> _inYear(
      int year, Map<String, Absence> Function(int year, int period) map) {
    final out = <Absence>[];
    for (final p in _periodsIn(year)) {
      for (final a in map(year, p).values) {
        if (settings.periodIndexFor(a.from) == p) out.add(a);
      }
    }
    return out..sort((a, b) => a.from.compareTo(b.from));
  }

  Map<String, Absence> _halfHolidayMap(int year, int period) {
    if (!_settingsOf(period).halfHolidays) return const {};
    return _christmasMap(year, period);
  }

  /// Heiligabend und Silvester – halb oder ganz frei je nach Einstellung.
  Map<String, Absence> _christmasMap(int year, int period) =>
      _christmasByYear.putIfAbsent('$year/$period', () => {
          for (final h in halfHolidaysFor(year))
            dayKey(h.date): Absence(
              id: 'christmas-${dayKey(h.date)}',
              type: AbsenceType.holiday,
              from: h.date,
              to: h.date,
              note: h.name,
              half: _settingsOf(period).halfHolidays,
            ),
        });

  /// Halber Feiertag am [day], falls vorhanden.
  Absence? halfHolidayFor(DateTime day) =>
      _halfHolidayMap(day.year, settings.periodIndexFor(day))[dayKey(day)];

  /// Arbeitstage, die [a] belegt: halbe Feiertage zählen halb, ganze
  /// Feiertage gar nicht (außer [a] ist selbst ein Feiertag).
  double workdaysOf(Absence a) {
    var n = 0.0;
    for (var d = a.from;
        !d.isAfter(a.to);
        d = DateTime(d.year, d.month, d.day + 1)) {
      if (!settingsFor(d).workdays.contains(d.weekday)) continue;
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
  List<Absence> holidaysIn(int year) => _inYear(year, _holidayMap);

  Map<String, Absence> _holidayMap(int year, int period) {
    final s = _settingsOf(period);
    final state = s.federalState;
    return _holidaysByYear.putIfAbsent('$year/$period', () => {
          if (state != null)
            for (final h in holidaysFor(state, year))
              dayKey(h.date): Absence(
                id: 'holiday-${dayKey(h.date)}',
                type: AbsenceType.holiday,
                from: h.date,
                to: h.date,
                note: h.name,
              ),
          if (!s.halfHolidays) ..._christmasMap(year, period),
        });
  }

  Absence? holidayFor(DateTime day) =>
      _holidayMap(day.year, settings.periodIndexFor(day))[dayKey(day)];

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
    final settings = settingsFor(d);
    return DayStats(
      day: d,
      sessions: sessions,
      worked: worked,
      target: targetFor(d),
      absence: absenceFor(d),
      halfHoliday: halfHolidayFor(d),
      absenceWorkFactor: settings.absenceWorkFactor,
      lateWorked: _lateWorked(d, sessions),
      lateWorkMinutes: settings.lateWorkMinutes,
      lateWorkFactor: settings.lateWorkFactor,
      stackWorkFactors: settings.stackWorkFactors,
    );
  }

  /// Arbeitszeit des Tages nach der eingestellten Uhrzeit. Läuft eine
  /// Arbeitszeit über Mitternacht, zählt auch die Zeit danach als spät.
  Duration _lateWorked(DateTime day, List<WorkSession> sessions) {
    final minutes = settingsFor(day).lateWorkMinutes;
    if (minutes == null) return Duration.zero;
    final from = DateTime(day.year, day.month, day.day, 0, minutes);
    var total = Duration.zero;
    for (final s in sessions) {
      final end = s.end ?? now;
      if (!end.isAfter(from)) continue;
      final start = s.start.isAfter(from) ? s.start : from;
      total += end.difference(start);
    }
    return total;
  }

  /// Stundenkonto inkl. Startwert.
  ///
  /// Vergangene Tage zählen vollständig (nicht erfasste Arbeitstage gehen mit
  /// den Tagesstunden ins Minus). Der heutige Tag zählt erst nach Tagesende
  /// negativ – Überstunden von heute werden aber sofort gutgeschrieben.
  Duration balance() => balanceBefore(dayOf(now)) + balanceToday();

  /// Startwert plus alle Tage vor [day].
  Duration balanceBefore(DateTime day) {
    var total = Duration(minutes: settings.startBalanceMinutes);
    var d = settings.startDate;
    while (d.isBefore(day)) {
      total += statsFor(d).diff;
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return total;
  }

  /// Beitrag des heutigen Tages: nur Überstunden, Minus erst nach Tagesende.
  Duration balanceToday() {
    final today = dayOf(now);
    if (settings.startDate.isAfter(today)) return Duration.zero;
    final t = statsFor(today).diff;
    return t > Duration.zero ? t : Duration.zero;
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
