import 'package:antatime/balance.dart';
import 'package:antatime/holidays.dart';
import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> names(FederalState s, int y) =>
      holidaysFor(s, y).map((h) => h.name).toList();

  test('Ostersonntag', () {
    expect(easterSunday(2024), DateTime(2024, 3, 31));
    expect(easterSunday(2025), DateTime(2025, 4, 20));
    expect(easterSunday(2026), DateTime(2026, 4, 5));
    expect(easterSunday(2027), DateTime(2027, 3, 28));
  });

  test('Anzahl Feiertage 2026 je Bundesland', () {
    final expected = {
      FederalState.bw: 12,
      FederalState.by: 12,
      FederalState.be: 10,
      FederalState.bb: 12,
      FederalState.hb: 10,
      FederalState.hh: 10,
      FederalState.he: 10,
      FederalState.mv: 11,
      FederalState.ni: 10,
      FederalState.nw: 11,
      FederalState.rp: 11,
      FederalState.sl: 12,
      FederalState.sn: 11,
      FederalState.st: 11,
      FederalState.sh: 10,
      FederalState.th: 11,
    };
    for (final e in expected.entries) {
      expect(holidaysFor(e.key, 2026).length, e.value, reason: e.key.label);
    }
  });

  test('Bewegliche und besondere Feiertage', () {
    final by = holidaysFor(FederalState.by, 2026);
    DateTime dateOf(List<Holiday> l, String n) =>
        l.firstWhere((h) => h.name == n).date;
    expect(dateOf(by, 'Karfreitag'), DateTime(2026, 4, 3));
    expect(dateOf(by, 'Christi Himmelfahrt'), DateTime(2026, 5, 14));
    expect(dateOf(by, 'Pfingstmontag'), DateTime(2026, 5, 25));
    expect(dateOf(by, 'Fronleichnam'), DateTime(2026, 6, 4));
    expect(dateOf(holidaysFor(FederalState.sn, 2026), 'Buß- und Bettag'),
        DateTime(2026, 11, 18));
    expect(names(FederalState.be, 2025), contains('Tag der Befreiung'));
    expect(names(FederalState.be, 2026), isNot(contains('Tag der Befreiung')));
    expect(names(FederalState.ni, 2017), contains('Reformationstag'));
    expect(names(FederalState.nw, 2017), contains('Reformationstag'));
    expect(names(FederalState.nw, 2018), isNot(contains('Reformationstag')));
  });

  test('Feiertag am Arbeitstag zählt wie ein gearbeiteter Tag', () {
    // Donnerstag, 14. Mai 2026 (Christi Himmelfahrt), Freitag frei erfasst
    final thu = DateTime(2026, 5, 14);
    AppData d(FederalState? fs) => AppData(
          sessions: [],
          absences: [],
          settings: Settings(
              startDate: thu, dailyHours: 8, weeklyHours: 40, federalState: fs),
        );
    final now = DateTime(2026, 5, 15, 6);
    expect(BalanceCalculator(d(null), now).balance(),
        const Duration(hours: -8));
    final calc = BalanceCalculator(d(FederalState.he), now);
    expect(calc.balance(), Duration.zero);
    expect(calc.statsFor(thu).absence?.label, 'Christi Himmelfahrt');
  });

  test('Bundesland wird gespeichert und exportiert', () {
    final s = Settings(federalState: FederalState.sn);
    expect(Settings.fromJson(s.toJson()).federalState, FederalState.sn);
    expect(Settings.fromJson(Settings().toJson()).federalState, isNull);
  });

  group('Arbeit an Abwesenheitstagen', () {
    // Donnerstag, 14. Mai 2026 (Christi Himmelfahrt in Hessen)
    final thu = DateTime(2026, 5, 14);
    final now = DateTime(2026, 5, 15, 6);
    AppData d(double factor, {List<Absence>? absences, FederalState? fs}) =>
        AppData(
          sessions: [
            WorkSession(
                id: 'w',
                start: DateTime(2026, 5, 14, 8),
                end: DateTime(2026, 5, 14, 12)),
          ],
          absences: absences ?? [],
          settings: Settings(
              startDate: thu,
              dailyHours: 8,
              weeklyHours: 40,
              federalState: fs,
              absenceWorkFactor: factor),
        );

    test('zählt mit Faktor 1 voll als Überstunden', () {
      final c = BalanceCalculator(d(1, fs: FederalState.he), now);
      expect(c.statsFor(thu).diff, const Duration(hours: 4));
      expect(c.balance(), const Duration(hours: 4));
    });

    test('Faktor 2 am Feiertag zählt doppelt', () {
      final c = BalanceCalculator(d(2, fs: FederalState.he), now);
      expect(c.statsFor(thu).bonus, const Duration(hours: 4));
      expect(c.balance(), const Duration(hours: 8));
    });

    test('Faktor 1,5 im Urlaub', () {
      final c = BalanceCalculator(
          d(1.5, absences: [
            Absence(
                id: 'u', type: AbsenceType.vacation, from: thu, to: thu)
          ]),
          now);
      expect(c.balance(), const Duration(hours: 6));
    });

    test('Krank: kein Faktor', () {
      final c = BalanceCalculator(
          d(2, absences: [
            Absence(id: 'k', type: AbsenceType.sick, from: thu, to: thu)
          ]),
          now);
      expect(c.balance(), const Duration(hours: 4));
    });

    test('Normaler Arbeitstag: kein Faktor', () {
      final c = BalanceCalculator(d(2), now);
      expect(c.balance(), const Duration(hours: -4));
    });

    test('Faktor wird gespeichert', () {
      expect(
          Settings.fromJson(Settings(absenceWorkFactor: 1.5).toJson())
              .absenceWorkFactor,
          1.5);
      expect(Settings.fromJson({}).absenceWorkFactor, 1);
    });
  });
}
