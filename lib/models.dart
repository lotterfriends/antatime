import 'dart:math';

/// Normalisiert einen Zeitpunkt auf den Tagesbeginn (lokale Zeit).
DateTime dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

String dayKey(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

final _rnd = Random();

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(1 << 32).toRadixString(36)}';

/// Ein Arbeitszeit-Block. [end] == null bedeutet: läuft gerade.
class WorkSession {
  WorkSession({required this.id, required this.start, this.end, this.note});

  final String id;
  DateTime start;
  DateTime? end;
  String? note;

  bool get isRunning => end == null;

  Duration durationAt(DateTime now) {
    final e = end ?? now;
    final d = e.difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  WorkSession copy() =>
      WorkSession(id: id, start: start, end: end, note: note);

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': start.toIso8601String(),
        if (end != null) 'end': end!.toIso8601String(),
        if (note != null && note!.isNotEmpty) 'note': note,
      };

  factory WorkSession.fromJson(Map<String, dynamic> j) => WorkSession(
        id: j['id'] as String,
        start: DateTime.parse(j['start'] as String),
        end: j['end'] == null ? null : DateTime.parse(j['end'] as String),
        note: j['note'] as String?,
      );
}

enum AbsenceType {
  sick('Krank'),
  vacation('Urlaub'),
  other('Andere Abwesenheit');

  const AbsenceType(this.label);
  final String label;
}

/// Abwesenheit über einen oder mehrere Tage (inklusive [from] und [to]).
class Absence {
  Absence({
    required this.id,
    required this.type,
    required DateTime from,
    required DateTime to,
    this.note,
  })  : from = dayOf(from),
        to = dayOf(to);

  final String id;
  AbsenceType type;
  DateTime from;
  DateTime to;
  String? note;

  bool covers(DateTime day) {
    final d = dayOf(day);
    return !d.isBefore(from) && !d.isAfter(to);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'from': dayKey(from),
        'to': dayKey(to),
        if (note != null && note!.isNotEmpty) 'note': note,
      };

  factory Absence.fromJson(Map<String, dynamic> j) => Absence(
        id: j['id'] as String,
        type: AbsenceType.values.firstWhere((t) => t.name == j['type'],
            orElse: () => AbsenceType.other),
        from: DateTime.parse(j['from'] as String),
        to: DateTime.parse(j['to'] as String),
        note: j['note'] as String?,
      );
}

class Settings {
  Settings({
    this.startBalanceMinutes = 0,
    this.weeklyHours = 40,
    this.dailyHours = 8,
    Set<int>? workdays,
    DateTime? startDate,
    this.showNotification = true,
  })  : workdays = workdays ?? {1, 2, 3, 4, 5},
        startDate = dayOf(startDate ?? DateTime.now());

  /// Startwert des Stundenkontos in Minuten (kann negativ sein).
  int startBalanceMinutes;

  double weeklyHours;

  /// Soll-Stunden pro Arbeitstag.
  double dailyHours;

  /// Arbeitstage als [DateTime.weekday] (1 = Montag … 7 = Sonntag).
  Set<int> workdays;

  /// Ab diesem Tag wird das Stundenkonto berechnet.
  DateTime startDate;

  /// Start/Pause-Steuerung im Benachrichtigungsbereich anzeigen.
  bool showNotification;

  int get dailyTargetMinutes => (dailyHours * 60).round();

  Map<String, dynamic> toJson() => {
        'startBalanceMinutes': startBalanceMinutes,
        'weeklyHours': weeklyHours,
        'dailyHours': dailyHours,
        'workdays': workdays.toList()..sort(),
        'startDate': dayKey(startDate),
        'showNotification': showNotification,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        startBalanceMinutes: (j['startBalanceMinutes'] as num?)?.toInt() ?? 0,
        weeklyHours: (j['weeklyHours'] as num?)?.toDouble() ?? 40,
        dailyHours: (j['dailyHours'] as num?)?.toDouble() ?? 8,
        workdays: (j['workdays'] as List?)
            ?.map((e) => (e as num).toInt())
            .toSet(),
        startDate: j['startDate'] == null
            ? null
            : DateTime.parse(j['startDate'] as String),
        showNotification: j['showNotification'] as bool? ?? true,
      );
}

class AppData {
  AppData({
    required this.sessions,
    required this.absences,
    required this.settings,
  });

  final List<WorkSession> sessions;
  final List<Absence> absences;
  Settings settings;

  WorkSession? get running {
    for (final s in sessions) {
      if (s.isRunning) return s;
    }
    return null;
  }
}
