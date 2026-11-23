import 'package:antatime/models.dart';
import 'package:antatime/repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime t(int h) => DateTime(2026, 11, 23, h);

  test('Pause aus der Benachrichtigung geht beim Speichern nicht verloren', () {
    final base = [
      WorkSession(id: 'a', start: t(6), end: t(7)),
      WorkSession(id: 'run', start: t(8)),
    ];
    // Benachrichtigung: laufende Zeit pausiert.
    final theirs = [
      WorkSession(id: 'a', start: t(6), end: t(7)),
      WorkSession(id: 'run', start: t(8), end: t(10)),
    ];
    // Gleichzeitig (Sync): Notiz an a geändert, neue Zeit von einem anderen
    // Gerät, laufende Zeit unverändert übernommen.
    final ours = [
      WorkSession(id: 'a', start: t(6), end: t(7), note: 'Notiz'),
      WorkSession(id: 'run', start: t(8)),
      WorkSession(id: 'old', start: t(1), end: t(2)),
    ];
    final merged =
        Repository.rebaseSessions(base: base, theirs: theirs, ours: ours);
    expect(merged.map((s) => s.id), ['old', 'a', 'run']);
    expect(merged.firstWhere((s) => s.id == 'a').note, 'Notiz');
    expect(merged.firstWhere((s) => s.id == 'run').end, t(10));
  });

  test('Löschungen und neue Einträge beider Seiten', () {
    final base = [WorkSession(id: 'a', start: t(6), end: t(7))];
    // Benachrichtigung startet eine neue Zeit, wir löschen a.
    final theirs = [
      WorkSession(id: 'a', start: t(6), end: t(7)),
      WorkSession(id: 'n', start: t(9)),
    ];
    final merged =
        Repository.rebaseSessions(base: base, theirs: theirs, ours: []);
    expect(merged.map((s) => s.id), ['n']);

    // Beide ändern dieselbe Zeit: die Benachrichtigung gewinnt.
    final both = Repository.rebaseSessions(
      base: [WorkSession(id: 'r', start: t(8))],
      theirs: [WorkSession(id: 'r', start: t(8), end: t(10))],
      ours: [WorkSession(id: 'r', start: t(8), note: 'x')],
    );
    expect(both.single.end, t(10));
  });
}
