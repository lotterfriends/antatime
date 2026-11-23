import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 23, 12);
  DateTime t(int h, [int m = 0]) => DateTime(2026, 11, 23, h, m);
  AppData data(List<WorkSession> s) =>
      AppData(sessions: s, absences: [], settings: Settings());

  test('Beginn, Ende und Zukunft', () {
    final d = data([]);
    expect(validateSession(d, WorkSession(id: 'n', start: t(8), end: t(10)), now),
        isNull);
    expect(validateSession(d, WorkSession(id: 'n', start: t(9), end: t(9)), now),
        contains('nach dem Beginn'));
    expect(validateSession(d, WorkSession(id: 'n', start: t(8), end: t(16)), now),
        contains('Ende liegt in der Zukunft'));
    expect(validateSession(d, WorkSession(id: 'n', start: t(13)), now),
        contains('Beginn liegt in der Zukunft'));
    // Über Mitternacht (gestern 22 Uhr bis heute 2 Uhr) ist erlaubt.
    expect(
        validateSession(
            d,
            WorkSession(
                id: 'n', start: DateTime(2026, 11, 22, 22), end: t(2)),
            now),
        isNull);
  });

  test('Überschneidung und zweite laufende Zeit', () {
    final d = data([
      WorkSession(id: 'a', start: t(8), end: t(10)),
      WorkSession(id: 'r', start: t(11)),
    ]);
    expect(validateSession(d, WorkSession(id: 'n', start: t(9), end: t(10, 30)), now),
        contains('Überschneidet sich mit 08:00–10:00'));
    expect(validateSession(d, WorkSession(id: 'n', start: t(10, 30)), now),
        contains('andere Arbeitszeit'));
    // Die Arbeitszeit selbst zählt nicht als Überschneidung.
    expect(validateSession(d, WorkSession(id: 'a', start: t(7), end: t(10)), now),
        isNull);
  });

  test('Inzwischen anderswo geändert: nicht überschreiben', () {
    final opened = WorkSession(id: 'r', start: t(8));
    // Beim Öffnen lief sie, inzwischen per Benachrichtigung pausiert.
    final d = data([WorkSession(id: 'r', start: t(8), end: t(11))]);
    final edited = WorkSession(id: 'r', start: t(8), note: 'Notiz');
    expect(validateSession(d, edited, now, original: opened),
        contains('inzwischen beendet'));
    expect(validateSession(data([]), edited, now, original: opened),
        contains('gelöscht'));
    expect(validateSession(data([opened.copy()]), edited, now, original: opened),
        isNull);
  });
}
