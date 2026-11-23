import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antatime/models.dart';
import 'package:antatime/sync/sync_crypto.dart';
import 'package:antatime/sync/sync_protocol.dart';
import 'package:antatime/sync/sync_records.dart';
import 'package:antatime/sync/sync_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

AppData sample() => AppData(
      sessions: [
        WorkSession(
            id: 'a',
            start: DateTime(2026, 11, 3, 8),
            end: DateTime(2026, 11, 3, 16, 30),
            note: 'Büro'),
      ],
      absences: [
        Absence(
            id: 'x',
            type: AbsenceType.vacation,
            from: DateTime(2026, 10, 1),
            to: DateTime(2026, 10, 3)),
      ],
      settings: Settings(startDate: DateTime(2026, 1, 1)),
    );

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));
  group('Code und Verschlüsselung', () {
    test('Codes sind gültig, zufällig und tolerant lesbar', () {
      final code = SyncCrypto.generateCode();
      expect(code, hasLength(SyncCrypto.codeLength));
      expect(SyncCrypto.normalizeCode(code), code);
      expect(SyncCrypto.generateCode(), isNot(code));

      final formatted = SyncCrypto.formatCode(code);
      expect(formatted.split('-'), hasLength(5));
      expect(SyncCrypto.normalizeCode(' ${formatted.toLowerCase()} '), code);
      expect(SyncCrypto.normalizeCode('0O1IL' * 5), '00111' * 5);
      expect(SyncCrypto.normalizeCode('ABC'), isNull);
      expect(SyncCrypto.normalizeCode('U' * 25), isNull);
    });

    test('Ableitung ist deterministisch und je Code verschieden', () async {
      final a1 = await SyncCrypto.fromCode('A' * 25);
      final a2 = await SyncCrypto.fromCode('A' * 25);
      final b = await SyncCrypto.fromCode('B' * 25);
      expect(a1.vaultId, hasLength(16));
      expect(a1.vaultId, a2.vaultId);
      expect(a1.vaultId, isNot(b.vaultId));
      expect(await a1.recordKey('s:1'), await a2.recordKey('s:1'));
      expect(await a1.recordKey('s:1'), isNot(await a1.recordKey('s:2')));
      expect(await a1.recordKey('s:1'), isNot(await b.recordKey('s:1')));
    });

    test('Verschlüsseln, Manipulation und falscher Schlüssel', () async {
      final c = await SyncCrypto.fromCode('C' * 25);
      final key = await c.recordKey('s:1');
      final plain = utf8.encode('{"k":"s:1","m":1}');
      final box = await c.encrypt(plain, key);
      expect(box.length, plain.length + 12 + 16);
      expect(await c.decrypt(box, key), plain);

      // Gleicher Klartext → anderer Chiffretext (zufällige Nonce).
      expect(await c.encrypt(plain, key), isNot(box));

      final tampered = Uint8List.fromList(box)..[20] ^= 1;
      await expectLater(c.decrypt(tampered, key),
          throwsA(isA<SecretBoxAuthenticationError>()));
      // An einen anderen Datensatz gebunden (AAD).
      await expectLater(c.decrypt(box, await c.recordKey('s:2')),
          throwsA(isA<SecretBoxAuthenticationError>()));
      final other = await SyncCrypto.fromCode('D' * 25);
      await expectLater(other.decrypt(box, key),
          throwsA(isA<SecretBoxAuthenticationError>()));
    });
  });

  group('Protokoll', () {
    test('HELLO und PUSH haben das erwartete Format', () {
      final hello = encodeHello(List.filled(16, 7), 300);
      expect(hello, [1, 1, ...List.filled(16, 7), 0xac, 0x02]);

      final push = encodePush(5, [
        WireRecord(Uint8List(16), Uint8List.fromList([1, 2, 3])),
      ]);
      expect(push, [2, 5, 1, ...List.filled(16, 0), 3, 1, 2, 3]);
    });

    test('Server-Nachrichten werden dekodiert', () {
      final changes = decodeServerMessage(Uint8List.fromList(
          [0x81, 1, 0x80, 0x01, ...List.filled(16, 9), 2, 4, 5]));
      expect(changes, isA<ChangesMessage>());
      final r = (changes as ChangesMessage).records.single;
      expect(r.seq, 128);
      expect(r.key, List.filled(16, 9));
      expect(r.data, [4, 5]);

      final ack = decodeServerMessage(Uint8List.fromList([0x83, 7, 9]));
      expect((ack as AckMessage).reqId, 7);
      expect(ack.firstSeq, 9);
      final synced = decodeServerMessage(Uint8List.fromList([0x82, 3]));
      expect((synced as SyncedMessage).headSeq, 3);
      expect(synced.serverTime, isNull, reason: 'älterer Server');
      final timed =
          decodeServerMessage(Uint8List.fromList([0x82, 3, 0x80, 0x01]));
      expect((timed as SyncedMessage).serverTime, 128);
      expect(timed.epoch, isNull);
      final withEpoch =
          decodeServerMessage(Uint8List.fromList([0x82, 3, 0x80, 0x01, 7]));
      expect((withEpoch as SyncedMessage).epoch, 7);
      expect(decodeServerMessage(Uint8List.fromList([0x85])),
          isA<VaultDeletedMessage>());
      expect(() => decodeServerMessage(Uint8List.fromList([0x81, 1])),
          throwsFormatException);
    });

    test('Server-Adresse wird zur WebSocket-URL', () {
      expect(SyncService.wsUri('sync.example.org').toString(),
          'wss://sync.example.org/sync');
      expect(SyncService.wsUri('http://localhost:8080').toString(),
          'ws://localhost:8080/sync');
      expect(SyncService.wsUri('https://x.de/antatime/').toString(),
          'wss://x.de/antatime/sync');
      expect(SyncService.wsUri('wss://x.de/sync').toString(), 'wss://x.de/sync');
    });
  });

  group('Datensätze und Zusammenführen', () {
    test('Doppelt gestartet: die zuerst gestartete Zeit gewinnt', () {
      AppData make(List<WorkSession> s) =>
          AppData(sessions: s, absences: [], settings: Settings());
      DateTime t(int h, [int m = 0]) => DateTime(2026, 11, 23, h, m);
      List<String> ids(AppData d) => d.sessions.map((s) => s.id).toList();
      final done = WorkSession(id: 'done', start: t(6), end: t(7));

      // Beide laufen noch.
      final phone = WorkSession(id: 'z', start: t(8));
      final pc = WorkSession(id: 'a', start: t(9), note: 'PC');
      final d = make([done.copy(), pc.copy(), phone.copy()]);
      expect(d.resolveOverlaps(), isTrue);
      expect(ids(d), ['done', 'z']);
      expect(d.sessions.last.note, 'PC', reason: 'Notiz bleibt erhalten');
      expect(d.resolveOverlaps(), isFalse);

      // Handy hat inzwischen pausiert, weitergemacht und Feierabend gemacht:
      // Pause und Ende bleiben, die PC-Zeit fällt weg.
      final paused = make([
        WorkSession(id: 'p1', start: t(8), end: t(10)),
        WorkSession(id: 'p2', start: t(10, 30), end: t(12)),
        pc.copy(),
      ]);
      expect(paused.resolveOverlaps(), isTrue);
      expect(ids(paused), ['p1', 'p2']);
      expect(paused.running, isNull);

      // Beendete Zeiten werden gekürzt statt entfernt: Ihr Ende zählt, die
      // Pause des anderen Geräts bleibt.
      final pcDone = make([
        WorkSession(id: 'p1', start: t(8), end: t(10)),
        WorkSession(id: 'p2', start: t(10, 30), end: t(12)),
        WorkSession(id: 'pc', start: t(9), end: t(13)),
      ]);
      expect(pcDone.resolveOverlaps(), isTrue);
      expect(ids(pcDone), ['p1', 'p2', 'pc']);
      expect(pcDone.sessions.last.start, t(12));
      expect(pcDone.sessions.last.end, t(13));
      expect(pcDone.resolveOverlaps(), isFalse);

      // Beitritt mit eigener Erfassung: keine Zeit geht verloren.
      final joined = make([
        WorkSession(id: 'h', start: t(8), end: t(9)),
        WorkSession(id: 'pc', start: t(8, 30), end: t(17)),
      ]);
      expect(joined.resolveOverlaps(), isTrue);
      expect(joined.sessions.map((s) => (s.start, s.end)),
          [(t(8), t(9)), (t(9), t(17))]);

      // Vollständig überdeckt: entfällt.
      final covered = make([
        WorkSession(id: 'h', start: t(8), end: t(12)),
        WorkSession(id: 'pc', start: t(9), end: t(11)),
      ]);
      expect(covered.resolveOverlaps(), isTrue);
      expect(ids(covered), ['h']);

      // Beendet, aber das andere Gerät erfasst noch: entfällt.
      final stillRunning = make([
        WorkSession(id: 'h', start: t(8)),
        WorkSession(id: 'pc', start: t(9), end: t(11)),
      ]);
      expect(stillRunning.resolveOverlaps(), isTrue);
      expect(ids(stillRunning), ['h']);

      // Erst nach dem Feierabend gestartet: kein Konflikt.
      final later = make([
        WorkSession(id: 'p1', start: t(8), end: t(12)),
        WorkSession(id: 'pc', start: t(13)),
      ]);
      expect(later.resolveOverlaps(), isFalse);

      // In der Pause gestartet: Die PC-Zeit begann zuerst, der spätere
      // Start am Handy ist der doppelte.
      final inPause = make([
        WorkSession(id: 'p1', start: t(8), end: t(10)),
        WorkSession(id: 'p2', start: t(10, 30), end: t(12)),
        WorkSession(id: 'pc', start: t(10, 15)),
      ]);
      expect(inPause.resolveOverlaps(), isTrue);
      expect(ids(inPause), ['p1', 'pc']);

      // Gleicher Start: auf allen Geräten dasselbe Ergebnis.
      final same = WorkSession(id: 'b', start: t(8));
      for (final order in [
        [phone, same],
        [same, phone],
      ]) {
        final x = make([for (final s in order) s.copy()]);
        x.resolveOverlaps();
        expect(x.sessions.single.id, 'b');
      }

      // Altlast des ursprünglichen Fehlers: zwei parallel erfasste, beendete
      // Zeiten. Die spätere ist vollständig überdeckt und entfällt; ihre
      // Notiz bleibt erhalten.
      final old = make([
        WorkSession(id: 'o1', start: t(8), end: t(17)),
        WorkSession(id: 'o2', start: t(9), end: t(17), note: 'PC'),
      ]);
      expect(old.resolveOverlaps(), isTrue);
      expect(ids(old), ['o1']);
      expect(old.sessions.single.note, 'PC');

      // Viele Arbeitszeiten ohne Überschneidung: nichts zu tun.
      final many = make([
        for (var i = 0; i < 5000; i++)
          WorkSession(
              id: 'm$i',
              start: DateTime(2020).add(Duration(hours: 3 * i)),
              end: DateTime(2020).add(Duration(hours: 3 * i + 2))),
      ]);
      final sw = Stopwatch()..start();
      expect(many.resolveOverlaps(), isFalse);
      expect(sw.elapsedMilliseconds, lessThan(200));
    });

    test('Alle Daten werden zu Datensätzen und zurück', () {
      final src = sample();
      final records = recordsOf(src);
      expect(records.keys, containsAll(['s:a', 'a:x', 'c:weeklyHours']));
      expect(records.keys.where((k) => k.startsWith('c:')),
          hasLength(syncedSettings.length));
      expect(records.containsKey('c:showNotification'), isFalse);

      final dst = AppData(
          sessions: [], absences: [], settings: Settings()..showNotification = false);
      records.forEach((name, content) =>
          applyRecord(dst, name, jsonDecode(content)));
      expect(recordsOf(dst), records);
      // Gerätebezogene Einstellung bleibt unberührt.
      expect(dst.settings.showNotification, isFalse);

      // Ungültiger Inhalt: Der bisherige Eintrag bleibt unverändert.
      final before = jsonEncode(dst.sessions.single.toJson());
      expect(() => applyRecord(dst, 's:a', {'id': 'a', 'start': 'kaputt'}),
          throwsFormatException);
      expect(() => applyRecord(dst, 's:a', 'kein Objekt'), throwsA(anything));
      expect(() => applyRecord(dst, 's:a', {'id': 'b', 'start': '2026-11-03T08:00:00.000'}),
          throwsFormatException);
      expect(jsonEncode(dst.sessions.single.toJson()), before);
      expect(() => applyRecord(dst, 'a:x', {'id': 'x'}), throwsA(anything));
      expect(dst.absences, hasLength(1));

      applyRecord(dst, 's:a', null, deleted: true);
      expect(dst.sessions, isEmpty);
      // Unbekannte Datensätze (neuere App-Version) werden ignoriert.
      applyRecord(dst, 'c:zukunft', 1);
      applyRecord(dst, 'z:1', {});
    });

    test('Lokale Änderungen werden erkannt', () {
      final data = sample();
      final st = SyncState(url: 'x', code: 'y');
      expect(st.diffLocal(recordsOf(data)), recordsOf(data).length);
      expect(st.pending, hasLength(recordsOf(data).length));
      st.acked(st.records.entries.map((e) => (e.key, e.value.modified)));
      expect(st.pending, isEmpty);
      expect(st.diffLocal(recordsOf(data)), 0);

      data.sessions.single.note = 'Homeoffice';
      data.absences.clear();
      expect(st.diffLocal(recordsOf(data)), 2);
      expect(st.records['a:x']!.content, isNull);
      expect(st.pending, unorderedEquals(['s:a', 'a:x']));
      expect(st.payload('a:x'), startsWith('{"k":"a:x","m":'));
      expect(jsonDecode(st.payload('s:a'))['v']['note'], 'Homeoffice');
    });

    test('Neuester Stand gewinnt, älterer wird erneut gesendet', () {
      final data = sample();
      final st = SyncState(url: 'x', code: 'y');
      st.diffLocal(recordsOf(data), DateTime.fromMillisecondsSinceEpoch(1000));
      st.acked(st.records.entries.map((e) => (e.key, e.value.modified)));
      final local = st.records['s:a']!.modified;

      final newer = data.sessions.single.toJson()..['note'] = 'neu';
      expect(st.applyRemote(data, 's:a', local + 10, newer, deleted: false),
          isTrue);
      expect(data.sessions.single.note, 'neu');
      expect(st.records['s:a']!.pending, isFalse);
      expect(st.clock, greaterThanOrEqualTo(local + 10));

      final older = data.sessions.single.toJson()..['note'] = 'alt';
      expect(st.applyRemote(data, 's:a', local + 5, older, deleted: false),
          isFalse);
      expect(data.sessions.single.note, 'neu');
      expect(st.records['s:a']!.pending, isTrue,
          reason: 'Server hat jetzt den älteren Stand → neueren erneut senden');

      expect(st.applyRemote(data, 's:a', local + 20, null, deleted: true),
          isTrue);
      expect(data.sessions, isEmpty);
      expect(st.records['s:a']!.content, isNull);
    });

    test('Beitreten: Server-Stand gewinnt, nur lokale Daten bleiben', () {
      final data = sample();
      final st = SyncState(url: 'x', code: 'y')..seedForJoin(recordsOf(data));
      expect(st.records.values.every((e) => e.modified == 0 && e.pending),
          isTrue);
      expect(st.applyRemote(data, 'c:weeklyHours', 5, 32.0, deleted: false),
          isTrue);
      expect(data.settings.weeklyHours, 32);
      expect(st.pending, isNot(contains('c:weeklyHours')));
      expect(st.pending, contains('s:a'));
    });

    test('Gleicher Zeitstempel, anderer Inhalt: alle Geräte einigen sich', () {
      // Zwei Geräte sind gleichzeitig einem leeren Code beigetreten: Beide
      // haben ihre Einstellung mit Zeitstempel 0.
      AppData dev(double h) => AppData(
          sessions: [], absences: [], settings: Settings()..weeklyHours = h);
      final a = dev(32), b = dev(40);
      final sa = SyncState(url: 'u', code: 'c')..seedForJoin(recordsOf(a));
      final sb = SyncState(url: 'u', code: 'c')..seedForJoin(recordsOf(b));
      // Jedes bekommt den Stand des anderen.
      sa.applyRemote(a, 'c:weeklyHours', 0, 40.0, deleted: false);
      sb.applyRemote(b, 'c:weeklyHours', 0, 32.0, deleted: false);
      // Das Gerät mit dem „kleineren“ Inhalt übernimmt, das andere sendet
      // seinen erneut – danach haben beide denselben Wert.
      final winner = '40.0'.compareTo('32.0') > 0 ? 40.0 : 32.0;
      expect(a.settings.weeklyHours, winner);
      expect(b.settings.weeklyHours, winner);
      final winnerState = winner == 40.0 ? sb : sa;
      expect(winnerState.records['c:weeklyHours']!.pending, isTrue,
          reason: 'Gewinner sendet erneut');
    });

    test('Zu große Datensätze blockieren die Übertragung nicht', () {
      expect(SyncService.tooLargeNotice(['s:x']), contains('Arbeitszeit'));
      expect(utf8.encode('x' * maxNoteLength * 4).length + 200,
          lessThan(SyncService.maxRecordBytes),
          reason: 'die längste Notiz passt (auch mit 4-Byte-Zeichen)');
    });

    test('Plattform-Unterschiede führen nicht zu erneutem Senden', () {
      final data = sample();
      final st = SyncState(url: 'x', code: 'y');
      // Fremdes Gerät liefert Mikrosekunden und 40 statt 40.0.
      final remote = {
        'id': 'b',
        'start': '2026-11-04T08:00:00.123456',
        'end': '2026-11-04T12:00:00.000',
      };
      st.applyRemote(data, 's:b', 5, remote, deleted: false);
      st.applyRemote(data, 'c:weeklyHours', 5, 40, deleted: false);
      expect(st.records['s:b']!.content, contentOf(data, 's:b'));
      st.diffLocal(recordsOf(data));
      expect(st.pending, isNot(contains('s:b')));
      expect(st.pending, isNot(contains('c:weeklyHours')));
    });

    test('Zustand übersteht Speichern und Laden', () {
      final st = SyncState(url: 'u', code: 'c', seq: 7)
        ..diffLocal(recordsOf(sample()));
      final back = SyncState.fromJson(
          jsonDecode(jsonEncode(st.toJson())) as Map<String, dynamic>);
      expect(back.seq, 7);
      expect(back.clock, st.clock);
      expect(back.pending.toSet(), st.pending.toSet());
      expect(back.records['s:a']!.content, st.records['s:a']!.content);
    });
  });

  group('Verbindung', () {
    test('Wartezeit hängt vom Grund der Trennung ab', () {
      Duration d(int attempt, [int? code, Object? reason]) =>
          SyncService.retryDelay(attempt, code, reason);
      expect(d(0), const Duration(seconds: 1));
      expect(d(3), const Duration(seconds: 10));
      expect(d(99), const Duration(seconds: 30));
      // Dauerhafte Fehler: nicht im Sekundentakt wiederholen.
      expect(d(0, SyncErrorCode.quotaExceeded), const Duration(minutes: 5));
      expect(d(0, SyncErrorCode.unsupportedVersion), const Duration(minutes: 5));
      expect(d(0, SyncErrorCode.rateLimited), const Duration(minutes: 1));
      // Server lehnt den Verbindungsaufbau wegen Limits ab:
      expect(d(0, null, 'HTTP status code: 429'), const Duration(minutes: 1));
      expect(d(0, SyncErrorCode.internal), const Duration(seconds: 1));
    });

    test('Verspätete Timer trennen nicht, sondern fragen nach', () {
      final t0 = DateTime(2026, 11, 13, 12);
      AliveCheck check(int nowS,
              {required int lastCheckS, required int lastRxS, int? probeS}) =>
          SyncService.aliveCheck(
            now: t0.add(Duration(seconds: nowS)),
            lastCheck: t0.add(Duration(seconds: lastCheckS)),
            lastRx: t0.add(Duration(seconds: lastRxS)),
            probeSentAt: probeS == null ? null : t0.add(Duration(seconds: probeS)),
          );
      // Timer pünktlich (alle 2 s):
      expect(check(4, lastCheckS: 2, lastRxS: 0), AliveCheck.ok);
      expect(check(12, lastCheckS: 10, lastRxS: 0), AliveCheck.probe);
      expect(check(14, lastCheckS: 12, lastRxS: 0, probeS: 12), AliveCheck.ok);
      expect(check(20, lastCheckS: 18, lastRxS: 0, probeS: 12), AliveCheck.dead);
      expect(check(30, lastCheckS: 28, lastRxS: 0), AliveCheck.dead);
      // Hintergrund-Tab: Timer erst nach einer Minute, die Verbindung hat
      // zuletzt vor 60 s etwas geschickt – erst nachfragen, nicht trennen.
      expect(check(60, lastCheckS: 0, lastRxS: 0), AliveCheck.probe);
      // Bleibt die Antwort auf diesen PING bis zum nächsten (wieder
      // verspäteten) Timer aus, ist die Verbindung tot.
      expect(check(120, lastCheckS: 60, lastRxS: 0, probeS: 60), AliveCheck.dead);
    });

    test('Kurze Unterbrechung erscheint nicht als Offline', () async {
      final sync = SyncService(_MemoryStore(),
          networkChanges: () => const Stream.empty());
      // Port 1: Verbindung wird sofort abgelehnt.
      await sync.enable(url: 'http://127.0.0.1:1', code: SyncCrypto.generateCode(), join: false);
      final sw = Stopwatch()..start();
      while (sync.status != SyncStatus.offline && sw.elapsed.inSeconds < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(sync.status, SyncStatus.offline);
      expect(sync.displayStatus, SyncStatus.connecting);
      await sync.disable();
      expect(sync.displayStatus, SyncStatus.off);
      sync.dispose();
    });

    test('Warten auf den Sync', () async {
      // Sync aus: sofort.
      final off = SyncService(_MemoryStore(),
          networkChanges: () => const Stream.empty());
      final sw = Stopwatch()..start();
      await off.waitUntilSynced(const Duration(seconds: 5));
      expect(sw.elapsedMilliseconds, lessThan(100));
      off.dispose();

      // Server nicht erreichbar: höchstens bis zur Wartezeit.
      final sync = SyncService(_MemoryStore(),
          networkChanges: () => const Stream.empty());
      await sync.enable(
          url: 'http://127.0.0.1:1', code: SyncCrypto.generateCode(), join: false);
      sw.reset();
      await sync.waitUntilSynced(const Duration(milliseconds: 300));
      expect(sw.elapsedMilliseconds, inInclusiveRange(250, 1000));

      // Sync wird währenddessen beendet: sofort weiter.
      final waiting = sync.waitUntilSynced(const Duration(seconds: 5));
      sw.reset();
      await sync.disable();
      await waiting;
      expect(sw.elapsedMilliseconds, lessThan(1000));
      sync.dispose();
    });

    test('Hinweis, wenn beim Beitreten die laufende Zeit verworfen wird', () {
      final now = DateTime(2026, 11, 23, 14);
      expect(
          SyncService.joinRunningDroppedNotice(DateTime(2026, 11, 23, 8, 30), now),
          allOf(contains('seit 08:30 Uhr'), contains('von heute')));
      expect(
          SyncService.joinRunningDroppedNotice(DateTime(2026, 11, 22, 8, 30), now),
          allOf(contains('seit 22.11.2026, 08:30 Uhr'),
              contains('vom 22.11.2026')));

      // resolveOverlaps meldet die entfernte Zeit.
      final d = AppData(sessions: [
        WorkSession(id: 'h', start: DateTime(2026, 11, 23, 8),
            end: DateTime(2026, 11, 23, 9)),
        WorkSession(id: 'pc', start: DateTime(2026, 11, 23, 8, 30)),
      ], absences: [], settings: Settings());
      final dropped = <WorkSession>[];
      d.resolveOverlaps(onDropped: dropped.add);
      expect(dropped.single.id, 'pc');
      expect(dropped.single.isRunning, isTrue);
    });

    test('Warnung bei falsch gehender Geräteuhr', () {
      final sync = SyncService(_MemoryStore(),
          networkChanges: () => const Stream.empty());
      expect(sync.clockWarning, isNull);
      sync.clockOffset = const Duration(seconds: 30);
      expect(sync.clockWarning, isNull);
      sync.clockOffset = const Duration(minutes: -15);
      expect(sync.clockWarning, contains('15 Minuten nach'));
      sync.clockOffset = const Duration(minutes: 5);
      expect(sync.clockWarning, contains('5 Minuten vor'));
      sync.dispose();
    });

    test('Ohne Leader-Rolle verbindet sich ein Tab nicht selbst', () async {
      final waiting = Completer<void Function()>();
      final sync = SyncService(_MemoryStore(),
          networkChanges: () => const Stream.empty(),
          leaderLock: (_) => waiting.future);
      await sync.enable(url: 'http://127.0.0.1:1', code: SyncCrypto.generateCode(), join: false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sync.status, SyncStatus.otherTab);
      expect(sync.displayStatus, SyncStatus.otherTab);
      // Beim Beenden darf die (spät gewährte) Rolle nicht hängen bleiben.
      var released = false;
      await sync.disable();
      waiting.complete(() => released = true);
      await Future<void>.delayed(Duration.zero);
      expect(released, isTrue);
      expect(sync.status, SyncStatus.off);
      sync.dispose();
    });
  });
}

class _MemoryStore implements SyncStore {
  String? _state;
  AppData _data = sample();

  @override
  Future<T> exclusive<T>(Future<T> Function() action) => action();
  @override
  Future<AppData> load() async => _data;
  @override
  Future<void> saveAll(AppData data) async => _data = data;
  @override
  Future<String?> loadSyncState() async => _state;
  @override
  Future<void> saveSyncState(String? json) async => _state = json;
}
