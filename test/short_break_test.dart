import 'package:antatime/balance.dart';
import 'package:antatime/models.dart';
import 'package:antatime/repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AppData data(List<WorkSession> sessions) =>
      AppData(sessions: sessions, absences: [], settings: Settings());

  test('Start innerhalb einer Minute setzt den Abschnitt fort', () {
    final d = data([
      WorkSession(
          id: 'a',
          start: DateTime(2026, 11, 5, 8),
          end: DateTime(2026, 11, 5, 12)),
    ]);
    expect(Repository.toggle(d, DateTime(2026, 11, 5, 12, 0, 59)), isTrue);
    expect(d.sessions, hasLength(1));
    expect(d.sessions.single.isRunning, isTrue);
  });

  test('Start nach einer Minute beginnt einen neuen Abschnitt', () {
    final d = data([
      WorkSession(
          id: 'a',
          start: DateTime(2026, 11, 5, 8),
          end: DateTime(2026, 11, 5, 12)),
    ]);
    expect(Repository.toggle(d, DateTime(2026, 11, 5, 12, 1)), isTrue);
    expect(d.sessions, hasLength(2));
    expect(d.sessions.first.end, DateTime(2026, 11, 5, 12));
  });

  test('Lücken unter einer Minute zählen nicht als Pause', () {
    final d = data([
      WorkSession(
          id: 'a',
          start: DateTime(2026, 11, 5, 8),
          end: DateTime(2026, 11, 5, 10)),
      WorkSession(
          id: 'b',
          start: DateTime(2026, 11, 5, 10, 0, 30),
          end: DateTime(2026, 11, 5, 12)),
      WorkSession(
          id: 'c',
          start: DateTime(2026, 11, 5, 12, 30),
          end: DateTime(2026, 11, 5, 16)),
    ]);
    final stats =
        BalanceCalculator(d, DateTime(2026, 11, 6)).statsFor(DateTime(2026, 11, 5));
    expect(stats.breaks, const Duration(minutes: 30));
  });
}
