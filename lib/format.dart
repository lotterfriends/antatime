import 'package:intl/intl.dart';

/// „H:MM“, z. B. 8:05. Negative Werte mit „−“.
String formatDuration(Duration d) {
  final neg = d.isNegative;
  final abs = d.abs();
  final h = abs.inHours;
  final m = abs.inMinutes.remainder(60);
  return '${neg ? '−' : ''}$h:${m.toString().padLeft(2, '0')}';
}

/// Mit Vorzeichen, z. B. +1:30 / −0:45.
String formatSigned(Duration d) =>
    d.isNegative ? formatDuration(d) : '+${formatDuration(d)}';

/// „H:MM:SS“ für die Live-Anzeige.
String formatClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String formatTime(DateTime dt) => DateFormat.Hm('de_DE').format(dt);

String formatDate(DateTime dt) => DateFormat('EE, dd.MM.yyyy', 'de_DE').format(dt);

String formatDateShort(DateTime dt) => DateFormat('dd.MM.yyyy', 'de_DE').format(dt);

String formatMonth(DateTime dt) => DateFormat.yMMMM('de_DE').format(dt);

const weekdayShort = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

/// Parst „8“, „8:30“, „-2:15“, „1,5“ in Minuten. Gibt null bei Fehler.
int? parseHoursToMinutes(String input) {
  var s = input.trim().replaceAll('−', '-');
  if (s.isEmpty) return 0;
  var sign = 1;
  if (s.startsWith('-')) {
    sign = -1;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  if (s.contains(':')) {
    final parts = s.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0].isEmpty ? '0' : parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || m < 0 || m >= 60) return null;
    return sign * (h * 60 + m);
  }
  final v = double.tryParse(s.replaceAll(',', '.'));
  if (v == null) return null;
  return sign * (v * 60).round();
}

String formatHoursNumber(double h) {
  final s = h.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '').replaceAll('.', ',');
}

/// Anzahl Arbeitstage, z. B. „1 Arbeitstag“, „4,5 Arbeitstage“.
String formatWorkdays(double n) =>
    '${formatHoursNumber(n)} Arbeitstag${n == 1 ? '' : 'e'}';

/// Faktor wie „1,5“ oder „2“.
String formatFactor(double f) => formatHoursNumber(f);

/// Liest einen Faktor wie „1,5“, „1.5“ oder „2“ (größer als 0, höchstens 10).
double? parseFactor(String input) {
  final v = double.tryParse(input.trim().replaceAll(',', '.'));
  if (v == null || v <= 0 || v > 10) return null;
  return v;
}

/// Uhrzeit aus Minuten nach Mitternacht, z. B. „20:00“.
String formatMinutesOfDay(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';
