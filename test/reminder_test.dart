import 'package:antatime/models.dart';
import 'package:antatime/reminder.dart';
import 'package:flutter_test/flutter_test.dart';

AppData _data({int? reminder = 9 * 60, List<WorkSession>? sessions,
    List<Absence>? absences, FederalState? state}) =>
    AppData(
      sessions: sessions ?? [],
      absences: absences ?? [],
      settings: Settings(
        startDate: DateTime(2026, 1, 1),
        reminderMinutes: reminder,
        federalState: state,
      ),
    );

void main() {
  // Montag, 7:00
  final monday = DateTime(2026, 11, 9, 7);

  test('ohne Uhrzeit keine Erinnerungen', () {
    expect(reminderTimes(_data(reminder: null), monday), isEmpty);
  });

  test('nur Arbeitstage zur eingestellten Uhrzeit', () {
    final times = reminderTimes(_data(), monday, days: 7);
    expect(times, [
      for (var d = 9; d <= 13; d++) DateTime(2026, 11, d, 9),
    ]);
  });

  test('heute entfällt, wenn schon gestartet', () {
    final data = _data(sessions: [
      WorkSession(
          id: 'a', start: DateTime(2026, 11, 9, 6), end: DateTime(2026, 11, 9, 6, 30)),
    ]);
    expect(reminderTimes(data, monday, days: 2), [DateTime(2026, 11, 10, 9)]);
  });

  test('heute entfällt, wenn die Uhrzeit vorbei ist', () {
    final times = reminderTimes(_data(), DateTime(2026, 11, 9, 9, 30), days: 2);
    expect(times, [DateTime(2026, 11, 10, 9)]);
  });

  test('keine Erinnerung bei Abwesenheit und an Feiertagen', () {
    final data = _data(
      state: FederalState.be,
      absences: [
        Absence(
            id: 'u',
            type: AbsenceType.vacation,
            from: DateTime(2026, 11, 10),
            to: DateTime(2026, 11, 11)),
      ],
    );
    expect(reminderTimes(data, monday, days: 3), [DateTime(2026, 11, 9, 9)]);
    // 25.12. ist Feiertag
    final xmas = reminderTimes(data, DateTime(2026, 12, 24, 10), days: 2);
    expect(xmas, isEmpty);
  });

  test('Einstellung wird gespeichert und gelesen', () {
    final s = Settings.fromJson(Settings(reminderMinutes: 510).toJson());
    expect(s.reminderMinutes, 510);
    expect(Settings.fromJson(Settings().toJson()).reminderMinutes, isNull);
  });

  group('Tagesstunden', () {
    final at10 = DateTime(2026, 11, 9, 10);

    test('Zeitpunkt beim Erreichen des Solls, inkl. früherer Arbeitszeit', () {
      final data = _data(sessions: [
        WorkSession(
            id: 'a',
            start: DateTime(2026, 11, 9, 7),
            end: DateTime(2026, 11, 9, 8)),
        WorkSession(id: 'b', start: DateTime(2026, 11, 9, 9)),
      ]);
      // 1 h + 1 h gearbeitet, 6 h fehlen
      expect(targetReachedAt(data, at10), DateTime(2026, 11, 9, 16));
    });

    test('keine Erinnerung ohne laufende Arbeitszeit oder wenn erreicht', () {
      expect(targetReachedAt(_data(), at10), isNull);
      final done = _data(sessions: [
        WorkSession(id: 'a', start: DateTime(2026, 11, 9, 1)),
      ]);
      expect(targetReachedAt(done, at10), isNull);
    });

    test('ausgeschaltet, am Wochenende oder bei Abwesenheit keine', () {
      final running = [WorkSession(id: 'a', start: DateTime(2026, 11, 9, 9))];
      final off = _data(sessions: running)..settings.targetReminder = false;
      expect(targetReachedAt(off, at10), isNull);
      expect(targetReminderDays(off, at10), isEmpty);

      final saturday = _data(sessions: [
        WorkSession(id: 'a', start: DateTime(2026, 11, 14, 9)),
      ]);
      expect(targetReachedAt(saturday, DateTime(2026, 11, 14, 10)), isNull);

      final vacation = _data(sessions: running, absences: [
        Absence(
            id: 'u',
            type: AbsenceType.vacation,
            from: DateTime(2026, 11, 9),
            to: DateTime(2026, 11, 9)),
      ]);
      expect(targetReachedAt(vacation, at10), isNull);
    });

    test('Soll-Zeiten der nächsten Arbeitstage', () {
      final days = targetReminderDays(_data(), at10, days: 7);
      expect(days.keys, [for (var d = 9; d <= 13; d++) DateTime(2026, 11, d)]);
      expect(days.values.toSet(), {const Duration(hours: 8)});
    });

    test('Einstellung wird gespeichert, Standard an', () {
      expect(Settings.fromJson(<String, dynamic>{}).targetReminder, isTrue);
      final s = Settings.fromJson(Settings(targetReminder: false).toJson());
      expect(s.targetReminder, isFalse);
    });
  });
}
