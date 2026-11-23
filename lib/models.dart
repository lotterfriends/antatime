import 'dart:math';

import 'holidays.dart';

export 'holidays.dart' show FederalState;

/// Normalisiert einen Zeitpunkt auf den Tagesbeginn (lokale Zeit).
DateTime dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

String dayKey(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

final _rnd = Random();

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(0x7fffffff).toRadixString(36)}';

/// Ein Arbeitszeit-Block. [end] == null bedeutet: läuft gerade.
/// Kürzere Unterbrechungen gelten nicht als Pause.
const minBreak = Duration(minutes: 1);

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
  other('Andere Abwesenheit'),

  /// Gesetzlicher Feiertag – wird automatisch aus dem Bundesland berechnet
  /// und nicht gespeichert.
  holiday('Feiertag');

  const AbsenceType(this.label);
  final String label;

  /// Typen, die man selbst eintragen kann.
  static const editable = [sick, vacation, other];
}

/// Abwesenheit über einen oder mehrere Tage (inklusive [from] und [to]).
class Absence {
  Absence({
    required this.id,
    required this.type,
    required DateTime from,
    required DateTime to,
    this.note,
    this.half = false,
  })  : from = dayOf(from),
        to = dayOf(to);

  final String id;
  AbsenceType type;
  DateTime from;
  DateTime to;
  String? note;

  /// Halber Feiertag (Heiligabend/Silvester) – nur bei Feiertagen, die
  /// automatisch berechnet und nicht gespeichert werden.
  final bool half;

  bool get isHoliday => type == AbsenceType.holiday;

  /// Anzeigename: bei Feiertagen der Name des Feiertags.
  String get label => isHoliday ? (note ?? type.label) : type.label;

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
    this.federalState,
    this.absenceWorkFactor = 1,
    this.lateWorkMinutes,
    this.lateWorkFactor = 1,
    this.stackWorkFactors = false,
    this.reminderMinutes,
    this.targetReminder = true,
    this.halfHolidays = true,
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

  /// Bundesland für die automatischen Feiertage (`null` = keine Feiertage).
  FederalState? federalState;

  /// Faktor für Arbeit an Feiertagen, im Urlaub und bei anderer
  /// Abwesenheit (z. B. 1,5 oder 2). 1 = jede Stunde zählt einfach.
  double absenceWorkFactor;

  /// Uhrzeit (Minuten nach Mitternacht), ab der Arbeit mit
  /// [lateWorkFactor] zählt (`null` = kein Spätarbeits-Faktor).
  int? lateWorkMinutes;

  /// Faktor für Arbeit nach [lateWorkMinutes] (z. B. 1,25 oder 1,5).
  /// Gilt nur für die Arbeitszeit selbst, nicht für Pausen.
  double lateWorkFactor;

  /// Treffen Abwesenheits- und Abend-Faktor zusammen (z. B. abends an einem
  /// Feiertag): `true` = die Zuschläge addieren sich, `false` = es gilt nur
  /// der höhere Faktor.
  bool stackWorkFactors;

  /// Uhrzeit (Minuten nach Mitternacht), zu der an Arbeitstagen an den
  /// Start der Zeiterfassung erinnert wird, falls noch nicht gestartet
  /// (`null` = keine Erinnerung).
  int? reminderMinutes;

  /// Benachrichtigen, sobald an einem Arbeitstag die Tagesstunden erreicht
  /// sind (nicht an Feiertagen und bei Abwesenheit).
  bool targetReminder;

  /// Heiligabend und Silvester sind halbe Feiertage: an diesen Tagen gilt
  /// nur die Hälfte der Tagesstunden. `false` = der Arbeitgeber schenkt die
  /// zweite Hälfte, die Tage sind ganz frei (wie ein Feiertag).
  bool halfHolidays;

  int get dailyTargetMinutes => (dailyHours * 60).round();

  Map<String, dynamic> toJson() => {
        'startBalanceMinutes': startBalanceMinutes,
        'weeklyHours': weeklyHours,
        'dailyHours': dailyHours,
        'workdays': workdays.toList()..sort(),
        'startDate': dayKey(startDate),
        'showNotification': showNotification,
        if (federalState != null) 'federalState': federalState!.name,
        'absenceWorkFactor': absenceWorkFactor,
        if (lateWorkMinutes != null) 'lateWorkMinutes': lateWorkMinutes,
        'lateWorkFactor': lateWorkFactor,
        'stackWorkFactors': stackWorkFactors,
        if (reminderMinutes != null) 'reminderMinutes': reminderMinutes,
        'targetReminder': targetReminder,
        'halfHolidays': halfHolidays,
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
        federalState: FederalState.byName(j['federalState'] as String?),
        absenceWorkFactor:
            (j['absenceWorkFactor'] as num?)?.toDouble() ?? 1,
        lateWorkMinutes: (j['lateWorkMinutes'] as num?)?.toInt(),
        lateWorkFactor: (j['lateWorkFactor'] as num?)?.toDouble() ?? 1,
        stackWorkFactors: j['stackWorkFactors'] as bool? ?? false,
        reminderMinutes: (j['reminderMinutes'] as num?)?.toInt(),
        targetReminder: j['targetReminder'] as bool? ?? true,
        halfHolidays: j['halfHolidays'] as bool? ?? true,
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

  /// Es wird immer nur eine Zeit gleichzeitig erfasst. Wurde die
  /// Zeiterfassung auf zwei Geräten gestartet, bevor der Sync den Stand des
  /// anderen kannte, gewinnt die zuerst gestartete. Für eine Arbeitszeit, die
  /// beginnt, während eine früher gestartete noch läuft bzw. lief, gilt:
  ///
  ///  * Läuft sie noch, ist sie ein doppelter Start und wird entfernt. Was
  ///    das andere Gerät inzwischen gemacht hat – Pause, erneuter Start,
  ///    Feierabend – bleibt so erhalten. Ihre Notiz wandert in die gewinnende.
  ///  * Ist sie beendet, zählt ihr Ende: Sie beginnt erst nach den
  ///    Arbeitszeiten, mit denen sie sich überschneidet. Reicht sie nicht
  ///    darüber hinaus, wird sie entfernt. So geht keine erfasste Zeit
  ///    verloren, z. B. wenn ein Gerät mit eigener Erfassung dem Sync beitritt.
  ///
  /// Bei gleichem Start entscheidet die ID, damit alle Geräte dasselbe
  /// Ergebnis erhalten. [onDropped] erfährt jede entfernte Arbeitszeit (im
  /// Zustand vor dem Entfernen). Gibt `true` zurück, wenn etwas geändert
  /// wurde.
  bool resolveOverlaps({void Function(WorkSession dropped)? onDropped}) {
    bool overlaps(WorkSession a, DateTime start, DateTime? end) =>
        (a.end == null || start.isBefore(a.end!)) &&
        (end == null || a.start.isBefore(end));

    // 1. Nach Start: Wer beginnt, während eine behaltene Arbeitszeit läuft
    //    bzw. lief, ist ein doppelter Start und wird zurückgestellt.
    final ordered = [...sessions]..sort((a, b) {
        final c = a.start.compareTo(b.start);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final kept = <WorkSession>[];
    final duplicates = <(WorkSession, WorkSession)>[];
    for (final s in ordered) {
      // Die behaltenen überschneiden sich nicht und sind nach Start sortiert:
      // Nur die letzte kann noch laufen bzw. über s.start hinausreichen.
      final last = kept.lastOrNull;
      final winner =
          last != null && overlaps(last, s.start, null) ? last : null;
      if (winner == null) {
        kept.add(s);
      } else {
        duplicates.add((s, winner));
      }
    }
    if (duplicates.isEmpty) return false;

    // 2. Doppelte Starts weichen allen anderen Arbeitszeiten: Laufende
    //    entfallen; beendete beginnen erst nach dem Ende der letzten, mit der
    //    sie sich überschneiden (so bleiben deren Pausen erhalten).
    final dropped = <WorkSession>{};
    for (final (s, winner) in duplicates) {
      final others = kept
          .where((k) => overlaps(k, s.start, s.end))
          .toList();
      DateTime? newStart;
      if (s.end != null && others.every((k) => k.end != null)) {
        newStart = others
            .map((k) => k.end!)
            .fold<DateTime>(s.start, (a, b) => b.isAfter(a) ? b : a);
      }
      if (newStart != null && newStart.isBefore(s.end!)) {
        s.start = newStart;
        kept.add(s);
        continue;
      }
      dropped.add(s);
      onDropped?.call(s.copy());
      final note = s.note?.trim();
      if (note != null &&
          note.isNotEmpty &&
          !(winner.note ?? '').contains(note)) {
        winner.note = [
          if (winner.note != null && winner.note!.trim().isNotEmpty)
            winner.note!,
          note,
        ].join('\n');
      }
    }
    sessions
      ..removeWhere(dropped.contains)
      ..sort((a, b) => a.start.compareTo(b.start));
    return true;
  }
}

/// Längste Arbeitszeit, die als „über Mitternacht“ gilt; längere Angaben
/// mit Ende vor Beginn sind eher Tippfehler.
const maxOvernight = Duration(hours: 16);

/// Prüft eine bearbeitete oder neue Arbeitszeit [s] gegen [data] (ohne sie
/// selbst). [original] ist der Stand beim Öffnen des Editors (`null` = neu):
/// Wurde die Arbeitszeit inzwischen anderswo geändert (Benachrichtigung,
/// Tray, anderes Gerät), wird nicht überschrieben.
/// Gibt eine Fehlermeldung zurück oder `null`, wenn alles passt.
String? validateSession(AppData data, WorkSession s, DateTime now,
    {WorkSession? original}) {
  if (original != null) {
    final current = data.sessions.where((x) => x.id == s.id).firstOrNull;
    if (current == null) {
      return 'Die Arbeitszeit wurde inzwischen gelöscht.';
    }
    if (current.start != original.start || current.end != original.end) {
      return current.isRunning == original.isRunning
          ? 'Die Arbeitszeit wurde inzwischen geändert. Bitte erneut öffnen.'
          : current.isRunning
              ? 'Die Arbeitszeit wurde inzwischen fortgesetzt. Bitte erneut öffnen.'
              : 'Die Arbeitszeit wurde inzwischen beendet. Bitte erneut öffnen.';
    }
  }
  if (s.start.isAfter(now)) return 'Beginn liegt in der Zukunft.';
  final end = s.end;
  if (end != null) {
    if (!end.isAfter(s.start)) return 'Ende muss nach dem Beginn liegen.';
    if (end.isAfter(now)) return 'Ende liegt in der Zukunft.';
  } else {
    final other = data.running;
    if (other != null && other.id != s.id) {
      return 'Es läuft bereits eine andere Arbeitszeit.';
    }
  }
  for (final o in data.sessions) {
    if (o.id == s.id) continue;
    final oEnd = o.end ?? now;
    final thisEnd = end ?? now;
    if (s.start.isBefore(oEnd) && thisEnd.isAfter(o.start)) {
      return 'Überschneidet sich mit ${_hm(o.start)}–'
          '${o.end == null ? 'jetzt' : _hm(o.end!)}.';
    }
  }
  return null;
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
