import 'package:antatime/balance.dart';
import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Donnerstag, 24. Dezember 2026, und Donnerstag, 31. Dezember 2026
  final xmasEve = DateTime(2026, 12, 24);
  final nye = DateTime(2026, 12, 31);
  final later = DateTime(2027, 1, 10);

  AppData data({List<Absence>? absences, bool halfHolidays = true}) => AppData(
        sessions: [],
        absences: absences ?? [],
        settings: Settings(
          startDate: DateTime(2026, 12, 21),
          dailyHours: 8,
          halfHolidays: halfHolidays,
        ),
      );

  test('Heiligabend und Silvester haben nur das halbe Soll', () {
    final calc = BalanceCalculator(data(), later);
    expect(calc.halfHolidayFor(xmasEve)?.label, 'Heiligabend');
    expect(calc.halfHolidayFor(nye)?.label, 'Silvester');
    expect(calc.targetFor(xmasEve), const Duration(hours: 4));
    expect(calc.targetFor(DateTime(2026, 12, 23)), const Duration(hours: 8));
    // Ohne Arbeit fehlt nur der halbe Tag.
    expect(calc.statsFor(xmasEve).diff, const Duration(hours: -4));
    expect(calc.absenceFor(xmasEve), isNull);
  });

  test('Urlaub am halben Feiertag zählt als halber Tag', () {
    final vacation = Absence(
      id: 'u',
      type: AbsenceType.vacation,
      from: DateTime(2026, 12, 21),
      to: DateTime(2027, 1, 1),
    );
    final calc = BalanceCalculator(data(absences: [vacation]), later);
    // Mo–Mi 21.–23. = 3, Do 24. = 0,5, Fr 25. Feiertag (ohne Bundesland
    // nicht gesetzlich) = 1, Mo–Mi 28.–30. = 3, Do 31. = 0,5, Fr 1.1. = 1
    expect(calc.workdaysOf(vacation), 9);
    expect(calc.statsFor(xmasEve).credited, const Duration(hours: 4));
    expect(calc.statsFor(xmasEve).diff, Duration.zero);

    final single = Absence(
        id: 'h', type: AbsenceType.vacation, from: xmasEve, to: xmasEve);
    expect(calc.workdaysOf(single), 0.5);
  });

  test('Ausgeschaltet: volle Tage wie bisher', () {
    final calc = BalanceCalculator(data(halfHolidays: false), later);
    expect(calc.halfHolidayFor(xmasEve), isNull);
    expect(calc.targetFor(xmasEve), const Duration(hours: 8));
    expect(calc.halfHolidaysIn(2026), isEmpty);
  });

  test('Einstellung wird gespeichert, fehlt sie, ist sie an', () {
    final s = Settings(halfHolidays: false);
    expect(Settings.fromJson(s.toJson()).halfHolidays, isFalse);
    expect(Settings.fromJson({}).halfHolidays, isTrue);
  });
}
