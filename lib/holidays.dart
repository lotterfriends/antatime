/// Gesetzliche Feiertage in Deutschland je Bundesland.
///
/// Berücksichtigt werden landesweit geltende Feiertage. Feiertage, die nur in
/// einzelnen Gemeinden gelten (z. B. Mariä Himmelfahrt in Teilen Bayerns,
/// Fronleichnam in Teilen Sachsens/Thüringens, Augsburger Friedensfest),
/// sind nicht enthalten und können als Abwesenheit eingetragen werden.
library;

enum FederalState {
  bw('Baden-Württemberg'),
  by('Bayern'),
  be('Berlin'),
  bb('Brandenburg'),
  hb('Bremen'),
  hh('Hamburg'),
  he('Hessen'),
  mv('Mecklenburg-Vorpommern'),
  ni('Niedersachsen'),
  nw('Nordrhein-Westfalen'),
  rp('Rheinland-Pfalz'),
  sl('Saarland'),
  sn('Sachsen'),
  st('Sachsen-Anhalt'),
  sh('Schleswig-Holstein'),
  th('Thüringen');

  const FederalState(this.label);
  final String label;

  static FederalState? byName(String? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

class Holiday {
  const Holiday(this.date, this.name);
  final DateTime date;
  final String name;
}

/// Ostersonntag (Gregorianischer Kalender, Algorithmus nach Meeus/Jones/Butcher).
DateTime easterSunday(int year) {
  final a = year % 19;
  final b = year ~/ 100;
  final c = year % 100;
  final d = b ~/ 4;
  final e = b % 4;
  final f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4;
  final k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31;
  final day = (h + l - 7 * m + 114) % 31 + 1;
  return DateTime(year, month, day);
}

/// Alle gesetzlichen Feiertage des Jahres [year] in [state], nach Datum sortiert.
List<Holiday> holidaysFor(FederalState state, int year) {
  final easter = easterSunday(year);
  DateTime e(int offset) =>
      DateTime(easter.year, easter.month, easter.day + offset);
  bool in_(Set<FederalState> states) => states.contains(state);

  final list = <Holiday>[
    Holiday(DateTime(year, 1, 1), 'Neujahr'),
    if (in_({FederalState.bw, FederalState.by, FederalState.st}))
      Holiday(DateTime(year, 1, 6), 'Heilige Drei Könige'),
    if ((state == FederalState.be && year >= 2019) ||
        (state == FederalState.mv && year >= 2023))
      Holiday(DateTime(year, 3, 8), 'Internationaler Frauentag'),
    Holiday(e(-2), 'Karfreitag'),
    // Nur Brandenburg führt Oster- und Pfingstsonntag als eigene Feiertage.
    // Hessen nicht: Dort sind alle Sonntage gesetzliche Feiertage
    // (§ 1 HFeiertagsG), Oster- und Pfingstsonntag sind nur besonders
    // geschützt (§ 9) – wie Sonntage anderswo also kein eigener Eintrag.
    if (state == FederalState.bb) Holiday(easter, 'Ostersonntag'),
    Holiday(e(1), 'Ostermontag'),
    Holiday(DateTime(year, 5, 1), 'Tag der Arbeit'),
    if (state == FederalState.be && (year == 2020 || year == 2025))
      Holiday(DateTime(year, 5, 8), 'Tag der Befreiung'),
    Holiday(e(39), 'Christi Himmelfahrt'),
    if (state == FederalState.bb) Holiday(e(49), 'Pfingstsonntag'),
    Holiday(e(50), 'Pfingstmontag'),
    if (in_({
      FederalState.bw,
      FederalState.by,
      FederalState.he,
      FederalState.nw,
      FederalState.rp,
      FederalState.sl,
    }))
      Holiday(e(60), 'Fronleichnam'),
    if (state == FederalState.sl)
      Holiday(DateTime(year, 8, 15), 'Mariä Himmelfahrt'),
    if (state == FederalState.th && year >= 2019)
      Holiday(DateTime(year, 9, 20), 'Weltkindertag'),
    Holiday(DateTime(year, 10, 3), 'Tag der Deutschen Einheit'),
    if (year == 2017 ||
        in_({
          FederalState.bb,
          FederalState.mv,
          FederalState.sn,
          FederalState.st,
          FederalState.th,
        }) ||
        (year >= 2018 &&
            in_({
              FederalState.hb,
              FederalState.hh,
              FederalState.ni,
              FederalState.sh,
            })))
      Holiday(DateTime(year, 10, 31), 'Reformationstag'),
    if (in_({
      FederalState.bw,
      FederalState.by,
      FederalState.nw,
      FederalState.rp,
      FederalState.sl,
    }))
      Holiday(DateTime(year, 11, 1), 'Allerheiligen'),
    if (state == FederalState.sn) Holiday(_repentanceDay(year), 'Buß- und Bettag'),
    Holiday(DateTime(year, 12, 25), '1. Weihnachtsfeiertag'),
    Holiday(DateTime(year, 12, 26), '2. Weihnachtsfeiertag'),
  ];
  list.sort((a, b) => a.date.compareTo(b.date));
  return list;
}

/// Halbe Feiertage: Heiligabend und Silvester. Gesetzlich keine Feiertage,
/// aber vielerorts nur ein halber Arbeitstag.
List<Holiday> halfHolidaysFor(int year) => [
      Holiday(DateTime(year, 12, 24), 'Heiligabend'),
      Holiday(DateTime(year, 12, 31), 'Silvester'),
    ];

/// Buß- und Bettag: Mittwoch vor dem 23. November.
DateTime _repentanceDay(int year) {
  var d = DateTime(year, 11, 22);
  while (d.weekday != DateTime.wednesday) {
    d = DateTime(year, 11, d.day - 1);
  }
  return d;
}
