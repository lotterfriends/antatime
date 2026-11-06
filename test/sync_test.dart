import 'dart:convert';
import 'dart:typed_data';

import 'package:antatime/models.dart';
import 'package:antatime/sync/sync_crypto.dart';
import 'package:antatime/sync/sync_protocol.dart';
import 'package:antatime/sync/sync_records.dart';
import 'package:antatime/sync/sync_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

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
      expect(decodeServerMessage(Uint8List.fromList([0x82, 3])),
          isA<SyncedMessage>());
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
}
