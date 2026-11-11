import 'package:antatime/auto_track.dart';
import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

AppData _data({List<WorkSession>? sessions, List<Absence>? absences,
        FederalState? state}) =>
    AppData(
      sessions: sessions ?? [],
      absences: absences ?? [],
      settings: Settings(startDate: DateTime(2026, 1, 1), federalState: state),
    );

void main() {
  final monday = DateTime(2026, 11, 9, 8);
  final saturday = DateTime(2026, 11, 14, 8);

  test('aus: nie starten', () {
    expect(shouldAutoTrack(AutoTrack.off, _data(), monday), isFalse);
  });

  test('an Arbeitstagen: nur Mo–Fr', () {
    expect(shouldAutoTrack(AutoTrack.workdays, _data(), monday), isTrue);
    expect(shouldAutoTrack(AutoTrack.workdays, _data(), saturday), isFalse);
  });

  test('an Arbeitstagen: nicht bei Abwesenheit oder Feiertag', () {
    final vacation = _data(absences: [
      Absence(id: 'a', type: AbsenceType.vacation, from: monday, to: monday),
    ]);
    expect(shouldAutoTrack(AutoTrack.workdays, vacation, monday), isFalse);
    final christmas = DateTime(2026, 12, 25, 8);
    expect(
        shouldAutoTrack(AutoTrack.workdays, _data(state: FederalState.values.first),
            christmas),
        isFalse);
  });

  test('an Arbeitstagen: nicht nach Feierabend', () {
    expect(
        shouldAutoTrack(AutoTrack.workdays, _data(), monday, stoppedToday: true),
        isFalse);
  });

  test('immer: auch an freien Tagen', () {
    expect(shouldAutoTrack(AutoTrack.always, _data(), saturday), isTrue);
  });

  test('nie, wenn schon eine Arbeitszeit läuft', () {
    final running = _data(sessions: [
      WorkSession(id: 's', start: monday.subtract(const Duration(hours: 1))),
    ]);
    expect(shouldAutoTrack(AutoTrack.always, running, monday), isFalse);
    expect(shouldAutoTrack(AutoTrack.workdays, running, monday), isFalse);
  });

  test('unbekannter Wert wird zu aus', () {
    expect(AutoTrack.byName(null), AutoTrack.off);
    expect(AutoTrack.byName('xyz'), AutoTrack.off);
    expect(AutoTrack.byName('always'), AutoTrack.always);
  });
}
