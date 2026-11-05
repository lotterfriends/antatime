import 'package:antatime/models.dart';
import 'package:antatime/repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AppData data(List<WorkSession> sessions) =>
      AppData(sessions: sessions, absences: [], settings: Settings());

  test('Pause löschen fasst Abschnitte zusammen', () {
    final d = data([
      WorkSession(
        id: 'a',
        start: DateTime(2026, 11, 5, 8),
        end: DateTime(2026, 11, 5, 12),
        note: 'vor',
      ),
      WorkSession(
        id: 'b',
        start: DateTime(2026, 11, 5, 12, 30),
        end: DateTime(2026, 11, 5, 17),
        note: 'nach',
      ),
    ]);
    expect(Repository.mergeSessions(d, 'a', 'b'), isTrue);
    expect(d.sessions, hasLength(1));
    expect(d.sessions.single.start, DateTime(2026, 11, 5, 8));
    expect(d.sessions.single.end, DateTime(2026, 11, 5, 17));
    expect(d.sessions.single.note, 'vor\nnach');
  });

  test('Laufender Abschnitt bleibt nach dem Zusammenfassen laufend', () {
    final d = data([
      WorkSession(
        id: 'a',
        start: DateTime(2026, 11, 5, 8),
        end: DateTime(2026, 11, 5, 12),
      ),
      WorkSession(id: 'b', start: DateTime(2026, 11, 5, 12, 30)),
    ]);
    expect(Repository.mergeSessions(d, 'a', 'b'), isTrue);
    expect(d.sessions.single.isRunning, isTrue);
    expect(d.sessions.single.note, isNull);
  });

  test('Unbekannte ID ändert nichts', () {
    final d = data([
      WorkSession(
        id: 'a',
        start: DateTime(2026, 11, 5, 8),
        end: DateTime(2026, 11, 5, 12),
      ),
    ]);
    expect(Repository.mergeSessions(d, 'a', 'x'), isFalse);
    expect(d.sessions.single.end, DateTime(2026, 11, 5, 12));
  });
}
