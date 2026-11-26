import 'dart:convert';
import 'dart:math';

import '../models.dart';

/// Abbildung der App-Daten auf einzeln synchronisierte Datensätze:
///
///  * `s:<id>`   eine Arbeitszeit
///  * `a:<id>`   eine Abwesenheit
///  * `c:<feld>` eine Einstellung (ohne gerätebezogene wie die Benachrichtigung)
///
/// Inhalt ist jeweils der JSON-Text, wie ihn dieses Gerät erzeugt
/// („kanonisch“). Verglichen wird immer mit dem eigenen kanonischen Text,
/// damit Plattform-Unterschiede (z. B. Mikrosekunden nativ, Millisekunden im
/// Browser) keine Endlos-Synchronisation auslösen.
const syncedSettings = [
  'startBalanceMinutes',
  'weeklyHours',
  'dailyHours',
  'workdays',
  'startDate',
  'federalState',
  'absenceWorkFactor',
  'lateWorkMinutes',
  'lateWorkFactor',
  'stackWorkFactors',
  'halfHolidays',
  'periods',
];

Map<String, String> recordsOf(AppData data) {
  final out = <String, String>{};
  for (final s in data.sessions) {
    out['s:${s.id}'] = jsonEncode(s.toJson());
  }
  for (final a in data.absences) {
    out['a:${a.id}'] = jsonEncode(a.toJson());
  }
  final settings = data.settings.toJson();
  for (final f in syncedSettings) {
    out['c:$f'] = jsonEncode(settings[f]);
  }
  return out;
}

/// Kanonischer Inhalt eines einzelnen Datensatzes (`null` = nicht vorhanden).
String? contentOf(AppData data, String name) {
  final id = name.length > 2 ? name.substring(2) : '';
  switch (name.substring(0, min(2, name.length))) {
    case 's:':
      final s = data.sessions.where((s) => s.id == id).firstOrNull;
      return s == null ? null : jsonEncode(s.toJson());
    case 'a:':
      final a = data.absences.where((a) => a.id == id).firstOrNull;
      return a == null ? null : jsonEncode(a.toJson());
    case 'c:':
      if (!syncedSettings.contains(id)) return null;
      return jsonEncode(data.settings.toJson()[id]);
  }
  return null;
}

/// Übernimmt einen Datensatz in [data]. [value] ist der dekodierte JSON-Wert,
/// `deleted` = Datensatz wurde gelöscht. Unbekannte Datensätze (z. B. von
/// einer neueren App-Version) werden ignoriert.
///
/// Ungültige Inhalte werfen eine Ausnahme, bevor [data] verändert wird –
/// sonst würde der bisherige Eintrag entfernt und die Löschung an alle
/// Geräte verteilt.
void applyRecord(AppData data, String name, Object? value, {bool deleted = false}) {
  final id = name.length > 2 ? name.substring(2) : '';
  switch (name.substring(0, min(2, name.length))) {
    case 's:':
      final s =
          deleted ? null : WorkSession.fromJson(value as Map<String, dynamic>);
      if (s != null && s.id != id) throw const FormatException('ID passt nicht');
      data.sessions.removeWhere((s) => s.id == id);
      if (s != null) {
        data.sessions.add(s);
        data.sessions.sort((a, b) => a.start.compareTo(b.start));
      }
    case 'a:':
      final a =
          deleted ? null : Absence.fromJson(value as Map<String, dynamic>);
      if (a != null && a.id != id) throw const FormatException('ID passt nicht');
      data.absences.removeWhere((a) => a.id == id);
      if (a != null) {
        data.absences.add(a);
        data.absences.sort((a, b) => b.from.compareTo(a.from));
      }
    case 'c:':
      if (!syncedSettings.contains(id)) return;
      final json = data.settings.toJson();
      if (deleted || value == null) {
        json.remove(id);
      } else {
        json[id] = value;
      }
      data.settings = Settings.fromJson(json);
  }
}

/// Stand eines Datensatzes, wie er zuletzt synchronisiert wurde.
class SyncEntry {
  SyncEntry(this.content, this.modified,
      {this.pending = false, this.stopBase});

  /// Kanonischer Inhalt; `null` = gelöscht.
  String? content;

  /// Zeitstempel der Änderung (Hybrid-Uhr, ms) – neuester gewinnt.
  int modified;

  /// Lokale Änderung, die der Server noch nicht bestätigt hat.
  bool pending;

  /// Nur bei ausstehenden Änderungen, die eine laufende Arbeitszeit beendet
  /// haben (Pause/Feierabend): Zeitstempel des Stands, auf dem das beruhte.
  /// Siehe [SyncState.applyRemote].
  int? stopBase;

  List<Object?> toJson() => [
        content,
        modified,
        if (pending) 1,
        if (pending && stopBase != null) stopBase,
      ];

  factory SyncEntry.fromJson(List<dynamic> j) => SyncEntry(
      j[0] as String?, (j[1] as num).toInt(),
      pending: j.length > 2,
      stopBase: j.length > 3 ? (j[3] as num?)?.toInt() : null);
}

/// Hat die Arbeitszeit mit diesem Inhalt (JSON-Text bzw. dekodiert) ein Ende?
/// `null` = keine lesbare Arbeitszeit.
bool? _sessionEnded(Object? content) {
  try {
    final j = content is String ? jsonDecode(content) : content;
    if (j is! Map) return null;
    return j['endUtc'] != null || j['end'] != null;
  } catch (_) {
    return null;
  }
}

/// Lokaler Sync-Zustand (Code, Server, letzter Stand, Snapshot je Datensatz).
class SyncState {
  SyncState({
    required this.url,
    required this.code,
    this.seq = 0,
    this.clock = 0,
    this.epoch,
    this.serverKey,
    Map<String, SyncEntry>? records,
  }) : records = records ?? {};

  final String url;
  final String code;

  /// Server-Schlüssel, wenn der Server eine Anmeldung verlangt (siehe
  /// `ServerKey`); sonst `null`.
  String? serverKey;

  /// Höchste Sequenznummer des Servers, die vollständig übernommen ist.
  int seq;

  /// Epoche des Vaults beim letzten Abgleich (siehe SyncedMessage.epoch).
  int? epoch;

  /// Hybrid-Uhr: nie kleiner als ein bereits gesehener Zeitstempel.
  int clock;

  final Map<String, SyncEntry> records;

  int tick([DateTime? now]) =>
      clock = max((now ?? DateTime.now()).millisecondsSinceEpoch, clock + 1);

  /// Erkennt lokale Änderungen gegenüber dem Snapshot und markiert sie als
  /// ausstehend. Gibt die Anzahl der Änderungen zurück.
  ///
  /// [madeAt] (Datensatz → ms) nennt für Änderungen, die nicht die App selbst
  /// gemacht hat (Android-Benachrichtigung), den tatsächlichen Zeitpunkt –
  /// sonst bekämen sie den Zeitpunkt, an dem die App sie bemerkt.
  int diffLocal(Map<String, String> current,
      [DateTime? now, Map<String, int> madeAt = const {}]) {
    var changed = 0;
    current.forEach((name, content) {
      final e = records[name];
      if (e == null || e.content != content) {
        final at = madeAt[name];
        final modified =
            at == null ? tick(now) : max(at, (e?.modified ?? 0) + 1);
        clock = max(clock, modified);
        // Pause/Feierabend: Eine laufende Arbeitszeit wurde beendet.
        final stopped = e != null &&
            name.startsWith('s:') &&
            e.content != null &&
            _sessionEnded(e.content) == false &&
            _sessionEnded(content) == true;
        records[name] = SyncEntry(content, modified,
            pending: true, stopBase: stopped ? e.modified : null);
        changed++;
      }
    });
    records.forEach((name, e) {
      if (e.content != null && !current.containsKey(name)) {
        e
          ..content = null
          ..modified = tick(now)
          ..pending = true;
        changed++;
      }
    });
    return changed;
  }

  /// Beim Beitreten zu einem bestehenden Code: Lokale Daten gelten als
  /// „uralt“ (Zeitstempel 0). Was auf dem Server liegt, gewinnt; was nur auf
  /// diesem Gerät existiert, wird hochgeladen.
  void seedForJoin(Map<String, String> current) {
    records.clear();
    current.forEach((name, content) {
      records[name] = SyncEntry(content, 0, pending: true);
    });
  }

  /// Übernimmt einen Datensatz vom Server (Last-Writer-Wins nach Zeitstempel).
  /// Gibt `true` zurück, wenn [data] geändert wurde.
  ///
  /// Ausnahme: Wurde hier eine laufende Arbeitszeit beendet, ohne zu wissen,
  /// dass sie anderswo längst beendet (oder gelöscht) ist, gilt deren Stand –
  /// auch wenn er älter ist. Sonst würde „Pause“ auf einem Gerät, das tagelang
  /// nicht synchronisiert hat (z. B. ein alter Browser-Tab), das richtige Ende
  /// durch „jetzt“ ersetzen; die Arbeitszeit reichte dann über alle seither
  /// erfassten hinweg und würde sie verdrängen.
  bool applyRemote(AppData data, String name, int modified, Object? value,
      {required bool deleted}) {
    clock = max(clock, modified);
    final local = records[name];
    final base = local?.stopBase;
    final staleStop = local != null &&
        local.pending &&
        base != null &&
        modified > base &&
        (deleted || _sessionEnded(value) == true);
    if (staleStop) {
      // Weiter unten übernehmen.
    } else if (local != null && local.modified > modified) {
      // Unser Stand ist neuer. Falls er schon hochgeladen war, hat der Server
      // ihn gerade mit einem älteren überschrieben → erneut senden.
      local.pending = true;
      return false;
    }
    if (!staleStop && local != null && local.modified == modified) {
      final remote = deleted ? '' : jsonEncode(value);
      final mine = local.content ?? '';
      if (remote == mine) {
        // Derselbe Stand (z. B. eigenes Echo nach einem Verbindungsabbruch).
        local.pending = false;
        return false;
      }
      // Gleicher Zeitstempel, anderer Inhalt (z. B. zwei Geräte sind
      // gleichzeitig einem leeren Code beigetreten – alles mit Zeitstempel
      // 0): Der Inhalt entscheidet, damit alle Geräte denselben Stand
      // behalten statt jedes seinen eigenen.
      if (remote.compareTo(mine) < 0) {
        local.pending = true;
        return false;
      }
    }
    final before = contentOf(data, name);
    applyRecord(data, name, value, deleted: deleted);
    final after = contentOf(data, name);
    records[name] = SyncEntry(after, modified);
    return before != after;
  }

  Iterable<String> get pending =>
      records.entries.where((e) => e.value.pending).map((e) => e.key);

  /// Server hat [sent] (Name, Zeitstempel) gespeichert.
  void acked(Iterable<(String, int)> sent) {
    for (final (name, modified) in sent) {
      final e = records[name];
      if (e != null && e.modified == modified) e.pending = false;
    }
  }

  /// Nach Datenverlust auf dem Server: alles erneut hochladen.
  void resetRemote() {
    seq = 0;
    for (final e in records.values) {
      e.pending = true;
    }
  }

  /// Inhalt für den Server (wird anschließend verschlüsselt).
  String payload(String name) {
    final e = records[name]!;
    final head = '{"k":${jsonEncode(name)},"m":${e.modified}';
    return e.content == null ? '$head}' : '$head,"v":${e.content}}';
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'code': code,
        'seq': seq,
        'clock': clock,
        if (epoch != null) 'epoch': epoch,
        if (serverKey != null) 'serverKey': serverKey,
        'records': records.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory SyncState.fromJson(Map<String, dynamic> j) => SyncState(
        url: j['url'] as String,
        code: j['code'] as String,
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        clock: (j['clock'] as num?)?.toInt() ?? 0,
        epoch: (j['epoch'] as num?)?.toInt(),
        serverKey: j['serverKey'] as String?,
        records: (j['records'] as Map<String, dynamic>? ?? const {}).map(
            (k, v) => MapEntry(k, SyncEntry.fromJson(v as List<dynamic>))),
      );
}
