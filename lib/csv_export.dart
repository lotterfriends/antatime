import 'balance.dart';
import 'format.dart';
import 'models.dart';

/// CSV-Export der Arbeitszeiten für einen Zeitraum: eine Zeile je Tag und
/// eine Summenzeile. Trennzeichen Semikolon und Dezimalkomma, damit die
/// Datei in einer deutschen Tabellenkalkulation direkt richtig aufgeht.
/// Zeiten in Stunden als Dezimalzahl (z. B. 8,50), damit man damit rechnen
/// kann.
///
/// Die Differenz zählt wie im Stundenkonto: nur ab dem Erfassungsbeginn und
/// bis heute, heute nur im Plus.
String exportCsv(AppData data, DateTime from, DateTime to, {DateTime? now}) {
  final calc = BalanceCalculator(data, now ?? DateTime.now());
  final today = dayOf(calc.now);
  final first = dayOf(from);
  final last = dayOf(to);

  final rows = <List<String>>[
    [
      'Datum',
      'Wochentag',
      'Beginn',
      'Ende',
      'Arbeitszeit (h)',
      'Pausen (h)',
      'Soll (h)',
      'Zuschläge (h)',
      'Abwesenheit',
      'Differenz (h)',
      'Notizen',
    ],
  ];

  var worked = Duration.zero;
  var breaks = Duration.zero;
  var target = Duration.zero;
  var bonus = Duration.zero;
  var diff = Duration.zero;

  for (var d = first;
      !d.isAfter(last);
      d = DateTime(d.year, d.month, d.day + 1)) {
    final s = calc.statsFor(d);
    final sessions = s.sessions;
    final firstStart = s.firstStart;
    final lastEnd = s.lastEnd;
    final absence = s.absence ?? s.halfHoliday;
    final counts = !d.isBefore(data.settings.startDate) && !d.isAfter(today);
    Duration? dayDiff;
    if (counts) {
      dayDiff = d == today && s.diff.isNegative ? Duration.zero : s.diff;
      diff += dayDiff;
    }
    worked += s.worked;
    breaks += s.breaks;
    target += s.target;
    bonus += s.bonus;

    rows.add([
      formatDateShort(d),
      weekdayShort[d.weekday - 1],
      firstStart == null ? '' : formatTime(firstStart),
      lastEnd == null ? '' : formatTime(lastEnd),
      _hours(s.worked),
      _hours(s.breaks),
      _hours(s.target),
      _hours(s.bonus),
      absence == null
          ? ''
          : absence.half
              ? '${absence.label} (halb)'
              : absence.label,
      dayDiff == null ? '' : _hours(dayDiff),
      sessions
          .map((x) => x.note?.trim() ?? '')
          .where((n) => n.isNotEmpty)
          .join(' | '),
    ]);
  }

  rows.add([
    'Summe',
    '',
    '',
    '',
    _hours(worked),
    _hours(breaks),
    _hours(target),
    _hours(bonus),
    '',
    _hours(diff),
    '',
  ]);

  return '${rows.map((r) => r.map(_cell).join(';')).join('\r\n')}\r\n';
}

/// Stunden mit zwei Nachkommastellen und Dezimalkomma, z. B. „-1,25“.
String _hours(Duration d) {
  final s = (d.inSeconds / 3600).toStringAsFixed(2).replaceAll('.', ',');
  return s == '-0,00' ? '0,00' : s;
}

/// Zelle nach RFC 4180 in Anführungszeichen, falls nötig.
String _cell(String v) {
  if (!v.contains(RegExp(r'[;"\r\n]'))) return v;
  return '"${v.replaceAll('"', '""')}"';
}
