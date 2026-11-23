import 'dart:convert';
import 'dart:typed_data';

/// Binäres Sync-Protokoll v1 – Gegenstück zu antatime-server/src/protocol.ts.
///
/// Erstes Byte = Opcode, Zahlen als LEB128-Varint, Schlüssel 16 Byte.
class SyncOp {
  static const hello = 0x01;
  static const push = 0x02;
  static const deleteVault = 0x03;
  static const ping = 0x04;
  static const changes = 0x81;
  static const synced = 0x82;
  static const ack = 0x83;
  static const pong = 0x84;
  static const vaultDeleted = 0x85;
  static const error = 0x8f;
}

const protocolVersion = 1;

/// Fehlercodes des Servers (siehe `ErrorCode` in protocol.ts).
class SyncErrorCode {
  static const badRequest = 1;
  static const unsupportedVersion = 2;
  static const tooLarge = 3;
  static const rateLimited = 4;
  static const tooManyConnections = 5;
  static const internal = 6;
  static const quotaExceeded = 7;
}

class WireRecord {
  WireRecord(this.key, this.data, [this.seq = 0]);
  final Uint8List key;
  final Uint8List data;
  final int seq;
}

// ---------------------------------------------------------------------------
// Server → Client

sealed class ServerMessage {
  const ServerMessage();
}

class ChangesMessage extends ServerMessage {
  const ChangesMessage(this.records);
  final List<WireRecord> records;
}

class SyncedMessage extends ServerMessage {
  const SyncedMessage(this.headSeq, [this.serverTime]);
  final int headSeq;

  /// Uhrzeit des Servers (ms seit 1970); `null` bei älteren Servern.
  final int? serverTime;
}

class AckMessage extends ServerMessage {
  const AckMessage(this.reqId, this.firstSeq);
  final int reqId;
  final int firstSeq;
}

class PongMessage extends ServerMessage {
  const PongMessage();
}

class VaultDeletedMessage extends ServerMessage {
  const VaultDeletedMessage();
}

class ErrorMessage extends ServerMessage {
  const ErrorMessage(this.code, this.message);
  final int code;
  final String message;
}

class _Reader {
  _Reader(this.buf);
  final Uint8List buf;
  int pos = 0;

  int u8() {
    if (pos >= buf.length) throw const FormatException('Nachricht zu kurz');
    return buf[pos++];
  }

  int varint() {
    var result = 0;
    var factor = 1;
    for (var i = 0; i < 8; i++) {
      final b = u8();
      result += (b & 0x7f) * factor;
      if (b & 0x80 == 0) return result;
      factor *= 128;
    }
    throw const FormatException('Zahl zu groß');
  }

  Uint8List bytes(int n) {
    if (pos + n > buf.length) throw const FormatException('Nachricht zu kurz');
    final out = Uint8List.sublistView(buf, pos, pos + n);
    pos += n;
    return out;
  }
}

ServerMessage decodeServerMessage(Uint8List buf) {
  final r = _Reader(buf);
  final op = r.u8();
  switch (op) {
    case SyncOp.changes:
      final n = r.varint();
      return ChangesMessage([
        for (var i = 0; i < n; i++)
          (() {
            final seq = r.varint();
            final key = r.bytes(16);
            final data = r.bytes(r.varint());
            return WireRecord(key, data, seq);
          })(),
      ]);
    case SyncOp.synced:
      final head = r.varint();
      return SyncedMessage(head, r.pos < buf.length ? r.varint() : null);
    case SyncOp.ack:
      return AckMessage(r.varint(), r.varint());
    case SyncOp.pong:
      return const PongMessage();
    case SyncOp.vaultDeleted:
      return const VaultDeletedMessage();
    case SyncOp.error:
      final code = r.u8();
      return ErrorMessage(
          code, utf8.decode(buf.sublist(r.pos), allowMalformed: true));
  }
  throw FormatException('Unbekannter Opcode $op');
}

// ---------------------------------------------------------------------------
// Client → Server

class _Writer {
  final _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v);

  void varint(int v) {
    assert(v >= 0);
    while (v >= 0x80) {
      _b.addByte((v % 128) | 0x80);
      v = v ~/ 128;
    }
    _b.addByte(v);
  }

  void bytes(List<int> b) => _b.add(b);

  Uint8List finish() => _b.takeBytes();
}

Uint8List encodeHello(List<int> vaultId, int lastSeq) => (_Writer()
      ..u8(SyncOp.hello)
      ..u8(protocolVersion)
      ..bytes(vaultId)
      ..varint(lastSeq))
    .finish();

Uint8List encodePush(int reqId, List<WireRecord> records) {
  final w = _Writer()
    ..u8(SyncOp.push)
    ..varint(reqId)
    ..varint(records.length);
  for (final r in records) {
    w
      ..bytes(r.key)
      ..varint(r.data.length)
      ..bytes(r.data);
  }
  return w.finish();
}

final pingFrame = Uint8List.fromList([SyncOp.ping]);
final deleteVaultFrame = Uint8List.fromList([SyncOp.deleteVault]);
