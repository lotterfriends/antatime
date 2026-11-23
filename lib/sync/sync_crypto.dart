import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ende-zu-Ende-Verschlüsselung für den Sync.
///
/// Der Sync-Code (25 Zeichen Base32 = 125 Bit Zufall) ist das einzige
/// Geheimnis. Daraus werden per HKDF-SHA256 abgeleitet:
///  * die Vault-ID (16 Byte), unter der der Server die Daten ablegt,
///  * ein AES-256-GCM-Schlüssel für die Inhalte,
///  * ein HMAC-Schlüssel, der die Datensatz-Namen (z. B. `s:<id>`) auf
///    zufällig aussehende 16-Byte-Schlüssel abbildet.
/// Der Server sieht weder Code noch Schlüssel noch Klartext.
class SyncCrypto {
  SyncCrypto._(this.vaultId, this._encKey, this._macKey);

  static const codeLength = 25;

  /// Zusätzliche Bytes durch die Verschlüsselung: Nonce (12) und Tag (16).
  static const overhead = 12 + 16;

  /// Crockford-Base32 (ohne I, L, O, U – verwechslungsarm).
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static final _aes = AesGcm.with256bits();
  static final _hmac = Hmac.sha256();
  static final _salt = utf8.encode('antatime-sync-v1');

  final Uint8List vaultId;
  final SecretKey _encKey;
  final SecretKey _macKey;
  final _keyCache = <String, Uint8List>{};

  /// Neuer, zufälliger Sync-Code.
  static String generateCode() {
    final rnd = Random.secure();
    return String.fromCharCodes(List.generate(
        codeLength, (_) => _alphabet.codeUnitAt(rnd.nextInt(_alphabet.length))));
  }

  /// Normalisiert eine Eingabe (Groß-/Kleinschreibung, Leerzeichen,
  /// Bindestriche, O→0, I/L→1). `null`, wenn kein gültiger Code.
  static String? normalizeCode(String input) {
    final s = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-_.]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (s.length != codeLength) return null;
    for (final c in s.codeUnits) {
      if (!_alphabet.codeUnits.contains(c)) return null;
    }
    return s;
  }

  /// Gut lesbar in Fünfergruppen: `ABCDE-FGHJK-…`.
  static String formatCode(String code) => [
        for (var i = 0; i < code.length; i += 5)
          code.substring(i, min(i + 5, code.length))
      ].join('-');

  static Future<SyncCrypto> fromCode(String code) async {
    final ikm = SecretKey(utf8.encode(code));
    Future<List<int>> derive(String info) async {
      final k = await Hkdf(hmac: _hmac, outputLength: 32)
          .deriveKey(secretKey: ikm, nonce: _salt, info: utf8.encode(info));
      return k.extractBytes();
    }

    final vault = await derive('vault');
    return SyncCrypto._(
      Uint8List.fromList(vault.sublist(0, 16)),
      SecretKey(await derive('enc')),
      SecretKey(await derive('mac')),
    );
  }

  /// Schlüssel eines Datensatzes auf dem Server (16 Byte).
  Future<Uint8List> recordKey(String name) async {
    final cached = _keyCache[name];
    if (cached != null) return cached;
    final mac = await _hmac.calculateMac(utf8.encode(name), secretKey: _macKey);
    return _keyCache[name] = Uint8List.fromList(mac.bytes.sublist(0, 16));
  }

  /// Verschlüsselt [plain]; Ergebnis: Nonce (12) ‖ Chiffretext ‖ Tag (16).
  /// [aad] (der Datensatz-Schlüssel) bindet den Inhalt an seinen Platz.
  Future<Uint8List> encrypt(List<int> plain, List<int> aad) async {
    final box = await _aes.encrypt(plain, secretKey: _encKey, aad: aad);
    return Uint8List.fromList(box.concatenation());
  }

  /// Entschlüsselt; wirft [SecretBoxAuthenticationError] bei Manipulation.
  Future<List<int>> decrypt(List<int> data, List<int> aad) {
    final box = SecretBox.fromConcatenation(data,
        nonceLength: _aes.nonceLength, macLength: _aes.macAlgorithm.macLength);
    return _aes.decrypt(box, secretKey: _encKey, aad: aad);
  }
}
