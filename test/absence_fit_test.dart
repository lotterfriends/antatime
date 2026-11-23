import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime d(int day) => DateTime(2026, 11, day);
  Absence a(String id, AbsenceType t, int from, int to) =>
      Absence(id: id, type: t, from: d(from), to: d(to));
  String show(List<Absence> l) => (l.toList()
        ..sort((x, y) => x.from.compareTo(y.from)))
      .map((x) => '${x.id}:${x.type.name}:${x.from.day}-${x.to.day}')
      .join(' ');
  var n = 0;
  String id() => 'neu${++n}';

  test('Krank mitten im Urlaub teilt den Urlaub', () {
    final urlaub = a('u', AbsenceType.vacation, 1, 10);
    final krank = a('k', AbsenceType.sick, 5, 6);
    expect(overlappingAbsences([urlaub], krank), [urlaub]);
    expect(show(fitAbsence([urlaub], krank, idFor: id)),
        'u:vacation:1-4 k:sick:5-6 neu1:vacation:7-10');
  });

  test('Am Rand kürzen, ganz überdeckt entfernen, Rest unberührt', () {
    final list = [
      a('a', AbsenceType.vacation, 1, 5),
      a('b', AbsenceType.other, 7, 7),
      a('c', AbsenceType.vacation, 8, 12),
      a('d', AbsenceType.vacation, 20, 21),
    ];
    expect(show(fitAbsence(list, a('k', AbsenceType.sick, 4, 9), idFor: id)),
        'a:vacation:1-3 k:sick:4-9 c:vacation:10-12 d:vacation:20-21');
  });

  test('Bearbeiten ersetzt die eigene, verlängern kürzt andere', () {
    final list = [
      a('u', AbsenceType.vacation, 1, 3),
      a('k', AbsenceType.sick, 5, 6),
    ];
    final longer = a('u', AbsenceType.vacation, 1, 5);
    expect(overlappingAbsences(list, longer).map((x) => x.id), ['k']);
    expect(show(fitAbsence(list, longer, idFor: id)),
        'u:vacation:1-5 k:sick:6-6');
  });
}
