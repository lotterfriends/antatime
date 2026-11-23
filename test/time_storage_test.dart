import 'dart:convert';

import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Exakter Zeitpunkt bleibt erhalten (auch in der doppelten Stunde)', () {
    // 25.10.2026, 02:10 MEZ = 01:10 UTC – die zweite „02:10“ des Tages.
    final second = DateTime.utc(2026, 10, 25, 1, 10).toLocal();
    final first = DateTime.utc(2026, 10, 25, 0, 40).toLocal();
    final s = WorkSession(id: 'a', start: first, end: second);
    final back = WorkSession.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.start.isAtSameMomentAs(first), isTrue);
    expect(back.end!.isAtSameMomentAs(second), isTrue);
    expect(back.end!.isAfter(back.start), isTrue);
    expect(back.start.isUtc, isFalse, reason: 'als Ortszeit weiterverwendet');
  });

  test('Ältere Daten ohne exakten Zeitpunkt: Ortszeit wie bisher', () {
    final s = WorkSession.fromJson({
      'id': 'a',
      'start': '2026-11-23T08:00:00.000',
      'end': '2026-11-23T12:00:00.000',
    });
    expect(s.start, DateTime(2026, 11, 23, 8));
    expect(s.end, DateTime(2026, 11, 23, 12));
    // Beim Speichern kommt der exakte Zeitpunkt dazu; die Ortszeit bleibt
    // für ältere Versionen unverändert.
    final j = s.toJson();
    expect(j['start'], '2026-11-23T08:00:00.000');
    expect(j['startUtc'], DateTime(2026, 11, 23, 8).toUtc().toIso8601String());
  });
}
