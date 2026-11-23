import 'package:antatime/csv_export.dart';
import 'package:antatime/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  AppData data() => AppData(
        sessions: [
          WorkSession(
              id: 'a',
              start: DateTime(2026, 11, 2, 8),
              end: DateTime(2026, 11, 2, 12),
              note: 'Büro; vormittags'),
          WorkSession(
              id: 'b',
              start: DateTime(2026, 11, 2, 12, 30),
              end: DateTime(2026, 11, 2, 17)),
        ],
        absences: [
          Absence(
              id: 'x',
              type: AbsenceType.vacation,
              from: DateTime(2026, 11, 3),
              to: DateTime(2026, 11, 3)),
        ],
        settings: Settings(startDate: DateTime(2026, 11, 1)),
      );

  test('Eine Zeile je Tag plus Kopf- und Summenzeile', () {
    final csv = exportCsv(data(), DateTime(2026, 11, 2), DateTime(2026, 11, 4),
        now: DateTime(2026, 11, 10));
    final lines = csv.trimRight().split('\r\n');

    expect(lines, hasLength(5));
    expect(lines[0], startsWith('Datum;Wochentag;Beginn;Ende;'));
    expect(lines[1],
        '02.11.2026;Mo;08:00;17:00;8,50;0,50;8,00;0,00;;0,50;"Büro; vormittags"');
    expect(lines[2], '03.11.2026;Di;;;0,00;0,00;8,00;0,00;Urlaub;0,00;');
    expect(lines[3], '04.11.2026;Mi;;;0,00;0,00;8,00;0,00;;-8,00;');
    expect(lines[4], 'Summe;;;;8,50;0,50;24,00;0,00;;-7,50;');
  });

  test('Vor Erfassungsbeginn und in der Zukunft keine Differenz', () {
    final csv = exportCsv(
        data(), DateTime(2026, 10, 30), DateTime(2026, 11, 12),
        now: DateTime(2026, 11, 10, 9));
    final lines = csv.trimRight().split('\r\n');

    // 30.10. (vor Erfassungsbeginn) und 11.11. (Zukunft): leer.
    expect(lines[1].split(';')[9], '');
    expect(lines[13].split(';')[9], '');
    // Heute zählt erst nach Tagesende negativ.
    expect(lines[12], startsWith('10.11.2026;'));
    expect(lines[12].split(';')[9], '0,00');
  });

  test('Notizen werden nicht als Formel ausgeführt', () {
    final d = data();
    d.sessions.first.note = '=HYPERLINK("http://x";"klick")';
    d.sessions.last.note = '-2+3';
    final csv = exportCsv(d, DateTime(2026, 11, 2), DateTime(2026, 11, 2),
        now: DateTime(2026, 11, 10));
    final line = csv.split('\r\n')[1];
    expect(line, endsWith('''"'=HYPERLINK(""http://x"";""klick"") | -2+3"'''));
  });
}
