import 'package:antatime/balance.dart';
import 'package:antatime/format.dart';
import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

WorkSession s(DateTime start, DateTime end) =>
    WorkSession(id: newId(), start: start, end: end);

void main() {
  // Montag, 2. November 2026
  final mon = DateTime(2026, 11, 2);
  DateTime at(DateTime day, int h, [int m = 0]) =>
      DateTime(day.year, day.month, day.day, h, m);

  AppData data({
    List<WorkSession>? sessions,
    List<Absence>? absences,
    int startBalance = 0,
  }) =>
      AppData(
        sessions: sessions ?? [],
        absences: absences ?? [],
        settings: Settings(
          startDate: mon,
          startBalanceMinutes: startBalance,
          dailyHours: 8,
          weeklyHours: 40,
        ),
      );

  test('9 Stunden an einem 8-Stunden-Tag ergeben +1', () {
    final d = data(sessions: [s(at(mon, 8), at(mon, 17))]);
    final calc = BalanceCalculator(d, at(mon.add(const Duration(days: 1)), 6));
    expect(calc.statsFor(mon).diff, const Duration(hours: 1));
    // Dienstag (heute) zählt noch nicht negativ.
    expect(calc.balance(), const Duration(hours: 1));
  });

  test('Lücke zwischen zwei Arbeitszeiten ist Pause', () {
    final d = data(sessions: [
      s(at(mon, 8), at(mon, 12)),
      s(at(mon, 12, 30), at(mon, 16, 30)),
    ]);
    final stats = BalanceCalculator(d, at(mon, 20)).statsFor(mon);
    expect(stats.worked, const Duration(hours: 8));
    expect(stats.breaks, const Duration(minutes: 30));
    expect(stats.diff, Duration.zero);
  });

  test('Nicht erfasster Arbeitstag zählt mit Tagesstunden ins Minus', () {
    final d = data(startBalance: 120);
    // Mittwoch: Mo + Di vergangen, beide ohne Eintrag.
    final calc = BalanceCalculator(d, at(DateTime(2026, 11, 4), 10));
    expect(calc.balance(), const Duration(hours: 2 - 16));
  });

  test('Wochenende zählt nicht ins Minus, Arbeit dort ist Plus', () {
    final sat = DateTime(2026, 11, 7);
    final d = data(sessions: [s(at(sat, 10), at(sat, 12))]);
    final calc = BalanceCalculator(d, at(DateTime(2026, 11, 9), 6));
    // Mo–Fr fehlen (−40), Samstag +2.
    expect(calc.balance(), const Duration(hours: -38));
  });

  test('Krank/Urlaub zählt wie voller Arbeitstag', () {
    final d = data(
      sessions: [
        s(at(mon, 8), at(mon, 16)),
      ],
      absences: [
        Absence(
            id: 'a',
            type: AbsenceType.vacation,
            from: DateTime(2026, 11, 3),
            to: DateTime(2026, 11, 8)),
      ],
    );
    final calc = BalanceCalculator(d, at(DateTime(2026, 11, 9), 6));
    expect(calc.balance(), Duration.zero);
  });

  test('Heute: Überstunden zählen sofort, Minus erst nach Tagesende', () {
    final d = data(sessions: [s(at(mon, 8), at(mon, 10))]);
    expect(BalanceCalculator(d, at(mon, 11)).balance(), Duration.zero);
    final d2 = data(sessions: [s(at(mon, 6), at(mon, 16))]);
    expect(BalanceCalculator(d2, at(mon, 17)).balance(),
        const Duration(hours: 2));
  });

  test('Laufende Arbeitszeit wird live berechnet', () {
    final d = data(sessions: [WorkSession(id: 'x', start: at(mon, 8))]);
    final stats = BalanceCalculator(d, at(mon, 9, 15)).statsFor(mon);
    expect(stats.worked, const Duration(hours: 1, minutes: 15));
  });

  test('Stundeneingabe parsen', () {
    expect(parseHoursToMinutes('8'), 480);
    expect(parseHoursToMinutes('7:30'), 450);
    expect(parseHoursToMinutes('7,5'), 450);
    expect(parseHoursToMinutes('-2:15'), -135);
    expect(parseHoursToMinutes('abc'), null);
    expect(formatSigned(const Duration(minutes: -45)), '−0:45');
    expect(formatSigned(const Duration(minutes: 90)), '+1:30');
  });

  test('JSON Roundtrip', () {
    final d = data(sessions: [s(at(mon, 8), at(mon, 9))]);
    final json = d.sessions.first.toJson();
    final back = WorkSession.fromJson(json);
    expect(back.start, d.sessions.first.start);
    expect(back.end, d.sessions.first.end);
    final st = Settings.fromJson(d.settings.toJson());
    expect(st.workdays, {1, 2, 3, 4, 5});
    expect(st.startDate, mon);
  });
}
