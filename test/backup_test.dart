import 'package:antatime/models.dart';
import 'package:antatime/repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Export und Import ergeben dieselben Daten', () {
    final data = AppData(
      sessions: [
        WorkSession(
            id: 'a',
            start: DateTime(2026, 11, 3, 8),
            end: DateTime(2026, 11, 3, 16, 30),
            note: 'Büro'),
        WorkSession(id: 'b', start: DateTime(2026, 11, 5, 8, 46)),
      ],
      absences: [
        Absence(
            id: 'x',
            type: AbsenceType.vacation,
            from: DateTime(2026, 10, 1),
            to: DateTime(2026, 10, 3)),
      ],
      settings: Settings(
        startBalanceMinutes: -90,
        weeklyHours: 32,
        dailyHours: 8,
        workdays: {1, 2, 3, 4},
        startDate: DateTime(2026, 1, 1),
        showNotification: false,
      ),
    );

    final restored = Repository.importJson(Repository.exportJson(data));

    expect(restored.sessions.map((s) => s.toJson()),
        data.sessions.map((s) => s.toJson()));
    expect(restored.absences.map((a) => a.toJson()),
        data.absences.map((a) => a.toJson()));
    expect(restored.settings.toJson(), data.settings.toJson());
    expect(restored.running?.id, 'b');
  });

  test('Ungültige Dateien werden abgelehnt', () {
    expect(() => Repository.importJson('kein json'), throwsFormatException);
    expect(() => Repository.importJson('{"foo": 1}'), throwsFormatException);
    expect(
        () => Repository.importJson(
            '{"format": "antatime-backup", "version": 1, "sessions": [{"x": 1}]}'),
        throwsFormatException);
    expect(
        () => Repository.importJson(
            '{"format": "antatime-backup", "version": 99}'),
        throwsFormatException);
  });
}
