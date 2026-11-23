import 'dart:convert';

import 'package:antatime/balance.dart';
import 'package:antatime/models.dart';
import 'package:antatime/sync/sync_records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mo 2.11.2026 bis So 22.11.2026, „heute“ ist Mo 23.11.
  final now = DateTime(2026, 11, 23, 12);

  AppData make(Settings s) {
    final sessions = <WorkSession>[];
    // Jeden Mo–Fr 8 Stunden gearbeitet.
    for (var d = DateTime(2026, 11, 2);
        d.isBefore(DateTime(2026, 11, 23));
        d = DateTime(d.year, d.month, d.day + 1)) {
      if (d.weekday > 5) continue;
      sessions.add(WorkSession(
          id: 's${d.day}',
          start: DateTime(d.year, d.month, d.day, 8),
          end: DateTime(d.year, d.month, d.day, 16)));
    }
    return AppData(sessions: sessions, absences: [], settings: s);
  }

  test('Weniger Arbeitstage ab heute ändern das Konto nicht rückwirkend', () {
    final s = Settings(startDate: DateTime(2026, 11, 2));
    expect(BalanceCalculator(make(s), now).balance(), Duration.zero);

    // Freitag abgewählt, die alten Werte gelten bis gestern.
    final before = s.periodValues();
    s.workdays.remove(5);
    s.periods = [SettingsPeriod(DateTime(2026, 11, 22), before)];
    final calc = BalanceCalculator(make(s), now);
    expect(calc.balance(), Duration.zero);
    expect(calc.targetFor(DateTime(2026, 11, 20)), const Duration(hours: 8));
    expect(calc.targetFor(DateTime(2026, 11, 27)), Duration.zero);

    // Rückwirkend: jeder bisherige Freitag zählt als Überstunden.
    s.periods = [];
    expect(BalanceCalculator(make(s), now).balance(),
        const Duration(hours: 24));
  });

  test('Bundesland gewechselt: Feiertage je Zeitraum', () {
    // Bis 31.10.2026 Sachsen (Reformationstag 31.10.), danach Bayern
    // (Allerheiligen 1.11.).
    final s = Settings(
        startDate: DateTime(2026, 1, 1), federalState: FederalState.by);
    final before = (Settings(federalState: FederalState.sn)
          ..workdays = {1, 2, 3, 4, 5, 6, 7})
        .periodValues();
    s.workdays = {1, 2, 3, 4, 5, 6, 7};
    s.periods = [SettingsPeriod(DateTime(2026, 10, 31), before)];
    final calc = BalanceCalculator(make(s), now);
    expect(calc.holidayFor(DateTime(2026, 10, 31))?.note, 'Reformationstag');
    expect(calc.holidayFor(DateTime(2026, 11, 1))?.note, 'Allerheiligen');
    final names = calc.holidaysIn(2026).map((h) => h.note).toList();
    expect(names, contains('Reformationstag'));
    expect(names, contains('Allerheiligen'));
    // Buß- und Bettag (nur Sachsen) liegt nach dem Wechsel.
    expect(names, isNot(contains('Buß- und Bettag')));
  });

  test('Zeiträume werden gespeichert und synchronisiert', () {
    final s = Settings(startDate: DateTime(2026, 1, 1));
    s.periods = [SettingsPeriod(DateTime(2026, 6, 30), s.periodValues())];
    s.federalState = FederalState.be;
    final copy = Settings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(copy.periods.single.until, DateTime(2026, 6, 30));
    expect(copy.forPeriod(0).federalState, isNull,
        reason: 'fehlender Wert bleibt fehlend');
    expect(copy.forPeriod(-1).federalState, FederalState.be);

    final data = AppData(sessions: [], absences: [], settings: s);
    final records = recordsOf(data);
    expect(records.containsKey('c:periods'), isTrue);
    final dst = AppData(sessions: [], absences: [], settings: Settings());
    applyRecord(dst, 'c:periods', jsonDecode(records['c:periods']!));
    expect(dst.settings.periods.single.until, DateTime(2026, 6, 30));
  });
}
