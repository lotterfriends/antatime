import 'package:antatime/balance.dart';
import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Donnerstag, 14. Mai 2026 (Christi Himmelfahrt in Hessen)
  final thu = DateTime(2026, 5, 14);
  // Mittwoch, 13. Mai 2026 (normaler Arbeitstag)
  final wed = DateTime(2026, 5, 13);
  final later = DateTime(2026, 5, 20);

  WorkSession w(String id, DateTime day, int fromH, int fromM, int toH,
          int toM) =>
      WorkSession(
          id: id,
          start: DateTime(day.year, day.month, day.day, fromH, fromM),
          end: DateTime(day.year, day.month, day.day, toH, toM));

  AppData data(List<WorkSession> sessions,
          {int? lateFrom = 20 * 60,
          double lateFactor = 1.5,
          double absenceFactor = 1,
          bool stack = false,
          FederalState? fs}) =>
      AppData(
        sessions: sessions,
        absences: [],
        settings: Settings(
          startDate: wed,
          federalState: fs,
          absenceWorkFactor: absenceFactor,
          lateWorkMinutes: lateFrom,
          lateWorkFactor: lateFactor,
          stackWorkFactors: stack,
        ),
      );

  test('Arbeit nach der Uhrzeit bekommt den Faktor', () {
    // 12:00–22:00 = 10 h, davon 2 h nach 20 Uhr → +1 h Zuschlag
    final c = BalanceCalculator(data([w('a', wed, 12, 0, 22, 0)]), later);
    final s = c.statsFor(wed);
    expect(s.lateWorked, const Duration(hours: 2));
    expect(s.lateBonus, const Duration(hours: 1));
    expect(s.diff, const Duration(hours: 3)); // 10 h + 1 h − 8 h
  });

  test('Pausen nach der Uhrzeit bekommen keinen Faktor', () {
    // 12–19, Pause 19–21, 21–22: nur 1 h nach 20 Uhr gearbeitet
    final c = BalanceCalculator(
        data([w('a', wed, 12, 0, 19, 0), w('b', wed, 21, 0, 22, 0)]), later);
    final s = c.statsFor(wed);
    expect(s.breaks, const Duration(hours: 2));
    expect(s.lateWorked, const Duration(hours: 1));
    expect(s.lateBonus, const Duration(minutes: 30));
  });

  test('Uhrzeit ist frei wählbar', () {
    final c = BalanceCalculator(
        data([w('a', wed, 12, 0, 20, 0)], lateFrom: 18 * 60 + 30, lateFactor: 2),
        later);
    expect(c.statsFor(wed).lateBonus, const Duration(minutes: 90));
  });

  test('Über Mitternacht zählt auch die Zeit danach', () {
    final c = BalanceCalculator(
        data([
          WorkSession(
              id: 'a',
              start: DateTime(2026, 5, 13, 19),
              end: DateTime(2026, 5, 14, 1)),
        ], lateFactor: 2),
        later);
    expect(c.statsFor(wed).lateWorked, const Duration(hours: 5));
  });

  test('Laufende Arbeitszeit zählt bis jetzt', () {
    final c = BalanceCalculator(
        data([WorkSession(id: 'a', start: DateTime(2026, 5, 13, 19))]),
        DateTime(2026, 5, 13, 21, 30));
    expect(c.statsFor(wed).lateWorked, const Duration(minutes: 90));
  });

  test('Ausgeschaltet: kein Zuschlag', () {
    final c = BalanceCalculator(
        data([w('a', wed, 12, 0, 22, 0)], lateFrom: null), later);
    expect(c.statsFor(wed).bonus, Duration.zero);
  });

  test('Standard: abends an Abwesenheitstagen zählt nur der höhere Faktor',
      () {
    // Feiertag, Faktor 2; abends Faktor 1,5 → Abendstunde zählt 2 (kein Extra)
    final c = BalanceCalculator(
        data([w('a', thu, 18, 0, 19, 0), w('b', thu, 20, 30, 21, 30)],
            absenceFactor: 2, fs: FederalState.he),
        later);
    final s = c.statsFor(thu);
    expect(s.absenceBonus, const Duration(hours: 2));
    expect(s.lateBonus, Duration.zero);
    expect(s.diff, const Duration(hours: 4));
  });

  test('Standard: höherer Abend-Faktor zählt nur den Unterschied dazu', () {
    // Feiertag, Faktor 1,5; abends Faktor 2 → 1 h abends zählt 2 h
    final c = BalanceCalculator(
        data([w('a', thu, 20, 0, 21, 0)],
            absenceFactor: 1.5, lateFactor: 2, fs: FederalState.he),
        later);
    final s = c.statsFor(thu);
    expect(s.absenceBonus, const Duration(minutes: 30));
    expect(s.lateBonus, const Duration(minutes: 30));
    expect(s.diff, const Duration(hours: 2));
  });

  test('Addieren: Zuschläge summieren sich, Pausen nie', () {
    // Feiertag, Faktor 2; 18–19, Pause 19–20:30, 20:30–21:30 bei Faktor 1,5
    final c = BalanceCalculator(
        data([w('a', thu, 18, 0, 19, 0), w('b', thu, 20, 30, 21, 30)],
            absenceFactor: 2, stack: true, fs: FederalState.he),
        later);
    final s = c.statsFor(thu);
    expect(s.worked, const Duration(hours: 2));
    expect(s.absenceBonus, const Duration(hours: 2));
    expect(s.lateBonus, const Duration(minutes: 30));
    expect(s.diff, const Duration(minutes: 270));
  });

  test('Einstellungen werden gespeichert', () {
    final s = Settings.fromJson(
        Settings(lateWorkMinutes: 1230, lateWorkFactor: 1.25).toJson());
    expect(s.lateWorkMinutes, 1230);
    expect(s.lateWorkFactor, 1.25);
    expect(Settings.fromJson(Settings(stackWorkFactors: true).toJson())
        .stackWorkFactors, isTrue);
    final d = Settings.fromJson({});
    expect(d.lateWorkMinutes, isNull);
    expect(d.lateWorkFactor, 1);
    expect(d.stackWorkFactors, isFalse);
  });
}
