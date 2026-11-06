import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models.dart';
import 'hosting_server.dart';
import 'sync_crypto.dart';
import 'sync_protocol.dart';
import 'sync_records.dart';

/// Speicherzugriff, den der Sync braucht (umgesetzt vom Repository).
abstract class SyncStore {
  /// Führt [action] exklusiv aus – nie gleichzeitig mit anderen Änderungen
  /// der App-Daten, damit keine Änderung verloren geht.
  Future<T> exclusive<T>(Future<T> Function() action);
  Future<AppData> load();
  Future<void> saveAll(AppData data);
  Future<String?> loadSyncState();
  Future<void> saveSyncState(String? json);
}

enum SyncStatus { off, connecting, online, offline }

/// Optionale Synchronisation über einen AnTaTime-Server.
///
/// Ablauf: Nach dem Verbinden sendet die App HELLO mit der zuletzt
/// übernommenen Sequenznummer; der Server schickt alle neueren Datensätze und
/// danach SYNCED. Ab dann kommen Änderungen anderer Geräte sofort an, eigene
/// Änderungen werden als PUSH gesendet. Alles ist Ende-zu-Ende-verschlüsselt
/// (siehe [SyncCrypto]).
class SyncService extends ChangeNotifier {
  SyncService(this._store, {this.onRemoteData});

  /// Standard-Server, z. B. `flutter build web --dart-define=SYNC_URL=…`.
  static const defaultUrl = String.fromEnvironment('SYNC_URL');

  /// Vorschlag für die Einrichtung: der beim Build festgelegte Server, sonst
  /// der Server, der diese Web-App ausgeliefert hat.
  static String get suggestedUrl =>
      defaultUrl.isNotEmpty ? defaultUrl : (hostingServerUrl() ?? '');

  static const _maxPerPush = 200;
  static const _pingAfter = Duration(seconds: 20);
  static const _deadAfter = Duration(seconds: 45);
  static const _backoff = [1, 2, 5, 10, 20, 30];

  final SyncStore _store;

  /// Wird aufgerufen, nachdem Änderungen anderer Geräte gespeichert wurden.
  void Function(AppData data)? onRemoteData;

  SyncStatus status = SyncStatus.off;
  String? url;
  String? code;

  /// Letzter Verbindungsfehler (für die Anzeige).
  String? error;

  /// Einmaliger Hinweis, z. B. wenn ein anderes Gerät den Sync beendet hat.
  String? notice;

  bool get enabled => code != null;

  SyncCrypto? _crypto;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  int _generation = 0;
  bool _live = false;
  int _attempt = 0;
  Timer? _retryTimer;
  Timer? _pingTimer;
  DateTime _lastRx = DateTime.now();
  int _reqId = 0;
  ({int reqId, List<(String, int)> sent})? _inflight;
  Completer<void>? _deleteDone;

  Future<void> _chain = Future.value();
  bool _localQueued = false;
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Öffentliche API

  Future<void> start() async {
    final st = await _loadState();
    if (st == null) return;
    await _activate(st);
  }

  /// Sync einschalten. `join == false`: neuer Code, alle lokalen Daten werden
  /// hochgeladen. `join == true`: bestehender Code, die Daten werden
  /// zusammengeführt (bei Konflikten gewinnt der Server-Stand).
  Future<void> enable(
      {required String url, required String code, required bool join}) async {
    await _shutdown();
    final st = await _store.exclusive(() async {
      final data = await _store.load();
      final st = SyncState(url: url, code: code);
      final current = recordsOf(data);
      if (join) {
        st.seedForJoin(current);
      } else {
        st.diffLocal(current);
      }
      await _saveState(st);
      return st;
    });
    notice = null;
    await _activate(st);
  }

  /// Sync auf diesem Gerät beenden. Mit [deleteRemote] werden zusätzlich alle
  /// Daten auf dem Server gelöscht und der Code ungültig – die anderen Geräte
  /// beenden den Sync dann ebenfalls. Gibt `false` zurück, wenn das Löschen
  /// mangels Verbindung nicht möglich war.
  Future<bool> disable({bool deleteRemote = false}) async {
    if (deleteRemote) {
      if (!_live) return false;
      final done = _deleteDone = Completer<void>();
      _channel!.sink.add(deleteVaultFrame);
      try {
        await done.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        _deleteDone = null;
        return false;
      }
    }
    await _shutdown();
    await _enqueue(() => _store.saveSyncState(null));
    _reset();
    return true;
  }

  /// Nach lokalen Änderungen aufrufen (auch nach dem Neuladen von Daten,
  /// die z. B. die Benachrichtigung oder ein anderer Tab geändert hat).
  void localChanged() {
    if (_localQueued) return;
    _localQueued = true;
    _enqueue(() async {
      _localQueued = false;
      final stored = await _loadState();
      if (!await _followStoredState(stored) || stored == null) return;
      final changed = await _store.exclusive(() async {
        final data = await _store.load();
        final st = await _loadState();
        if (st == null) return false;
        if (st.diffLocal(recordsOf(data)) == 0) return false;
        await _saveState(st);
        return true;
      });
      if (changed) _schedulePush();
    });
  }

  /// Im Browser teilen sich mehrere Tabs denselben Speicher: Wurde der Sync
  /// in einem anderen Tab ein-, aus- oder auf einen anderen Code umgestellt,
  /// zieht dieser Tab nach. Gibt `true` zurück, wenn der Sync aktiv ist.
  Future<bool> _followStoredState(SyncState? stored) async {
    if (stored?.code == code) return stored != null;
    _stopLocal();
    if (stored == null) return false;
    await _activate(stored);
    return true;
  }

  /// Verbindung trennen, ohne den gespeicherten Zustand anzufassen.
  void _stopLocal() {
    _generation++;
    _retryTimer?.cancel();
    _closeChannel();
    if (enabled) _reset();
  }

  /// App kommt in den Vordergrund: Verbindung sofort wiederherstellen.
  void resume() {
    if (!enabled) return;
    if (status == SyncStatus.offline) {
      _retryTimer?.cancel();
      _attempt = 0;
      _connect();
    } else if (_channel != null) {
      _checkAlive(force: true);
    }
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _shutdown();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Zustand

  Future<SyncState?> _loadState() async {
    final raw = await _store.loadSyncState();
    if (raw == null) return null;
    try {
      return SyncState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('Sync-Zustand unlesbar: $e');
      return null;
    }
  }

  Future<void> _saveState(SyncState st) =>
      _store.saveSyncState(jsonEncode(st.toJson()));

  Future<void> _activate(SyncState st) async {
    url = st.url;
    code = st.code;
    _crypto = await SyncCrypto.fromCode(st.code);
    _attempt = 0;
    _connect();
  }

  void _reset() {
    url = null;
    code = null;
    _crypto = null;
    error = null;
    status = SyncStatus.off;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Serialisiert alle Sync-Schritte.
  Future<void> _enqueue(Future<void> Function() step) {
    final next = _chain.then((_) => step());
    _chain = next.catchError((Object e, StackTrace s) {
      debugPrint('Sync-Fehler: $e\n$s');
    });
    return _chain;
  }

  // ---------------------------------------------------------------------------
  // Verbindung

  static Uri wsUri(String url) {
    var s = url.trim();
    if (!s.contains('://')) s = 'https://$s';
    final u = Uri.parse(s);
    final scheme = switch (u.scheme) {
      'http' => 'ws',
      'https' => 'wss',
      final other => other,
    };
    final path = u.path.endsWith('/sync')
        ? u.path
        : '${u.path.replaceAll(RegExp(r'/+$'), '')}/sync';
    return u.replace(scheme: scheme, path: path);
  }

  Future<void> _connect() async {
    final gen = ++_generation;
    _closeChannel();
    status = SyncStatus.connecting;
    _notify();
    try {
      final ch = WebSocketChannel.connect(wsUri(url!));
      _channel = ch;
      await ch.ready.timeout(const Duration(seconds: 15));
      if (gen != _generation) return;
      _lastRx = DateTime.now();
      _sub = ch.stream.listen(
        (msg) => _onFrame(gen, msg),
        onDone: () => _onClosed(gen, ch.closeReason),
        onError: (Object e) => _onClosed(gen, e),
        cancelOnError: true,
      );
      final st = await _loadState();
      if (gen != _generation || st == null) return;
      ch.sink.add(encodeHello(_crypto!.vaultId, st.seq));
      _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkAlive());
    } catch (e) {
      _onClosed(gen, e);
    }
  }

  void _checkAlive({bool force = false}) {
    final idle = DateTime.now().difference(_lastRx);
    if (idle > _deadAfter) {
      _onClosed(_generation, 'Keine Antwort vom Server');
    } else if (force || idle > _pingAfter) {
      _channel?.sink.add(pingFrame);
    }
  }

  void _closeChannel() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _live = false;
    _inflight = null;
  }

  void _onClosed(int gen, Object? reason) {
    if (gen != _generation) return;
    _generation++;
    _closeChannel();
    if (!enabled || _disposed) return;
    status = SyncStatus.offline;
    if (reason != null) error = _describe(reason);
    _notify();
    final delay = _backoff[min(_attempt, _backoff.length - 1)];
    _attempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(
        Duration(milliseconds: delay * 1000 + Random().nextInt(500)), () {
      if (enabled && status == SyncStatus.offline) _connect();
    });
  }

  static String _describe(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('WebSocketChannelException')) {
      return 'Server nicht erreichbar';
    }
    return s;
  }

  Future<void> _shutdown() async {
    _generation++;
    _retryTimer?.cancel();
    _closeChannel();
    await _chain;
  }

  // ---------------------------------------------------------------------------
  // Nachrichten

  void _onFrame(int gen, dynamic msg) {
    if (gen != _generation) return;
    _lastRx = DateTime.now();
    final Uint8List bytes;
    if (msg is Uint8List) {
      bytes = msg;
    } else if (msg is ByteBuffer) {
      bytes = msg.asUint8List();
    } else if (msg is List<int>) {
      bytes = Uint8List.fromList(msg);
    } else {
      return;
    }
    final ServerMessage m;
    try {
      m = decodeServerMessage(bytes);
    } on FormatException catch (e) {
      debugPrint('Sync: ungültige Nachricht: $e');
      return;
    }
    switch (m) {
      case ChangesMessage(:final records):
        _enqueue(() => _applyRemote(gen, records));
      case SyncedMessage(:final headSeq):
        _enqueue(() => _onSynced(gen, headSeq));
      case AckMessage(:final reqId, :final firstSeq):
        _enqueue(() => _onAck(gen, reqId, firstSeq));
      case PongMessage():
        break;
      case VaultDeletedMessage():
        _enqueue(_onVaultDeleted);
      case ErrorMessage(:final message):
        error = message;
        _notify();
    }
  }

  Future<void> _applyRemote(int gen, List<WireRecord> wire) async {
    if (gen != _generation) return;
    final crypto = _crypto!;
    // Erst entschlüsseln (async), dann alles in einem Schritt anwenden.
    final decoded = <(int, String, int, Object?, bool)>[];
    for (final r in wire) {
      try {
        final plain = await crypto.decrypt(r.data, r.key);
        final j = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        final name = j['k'] as String;
        final key = await crypto.recordKey(name);
        if (!listEquals(key, r.key)) throw const FormatException('Schlüssel');
        decoded.add((r.seq, name, (j['m'] as num).toInt(), j['v'], !j.containsKey('v')));
      } catch (e) {
        debugPrint('Sync: Datensatz ${r.seq} übersprungen: $e');
        decoded.add((r.seq, '', 0, null, true));
      }
    }
    final pushNeeded = await _store.exclusive(() async {
      final data = await _store.load();
      final st = await _loadState();
      if (st == null) return false;
      st.diffLocal(recordsOf(data));
      var changed = false;
      for (final (seq, name, modified, value, deleted) in decoded) {
        if (name.isNotEmpty) {
          try {
            changed |= st.applyRemote(data, name, modified, value, deleted: deleted);
          } catch (e) {
            debugPrint('Sync: $name nicht übernommen: $e');
          }
        }
        st.seq = max(st.seq, seq);
      }
      if (changed) await _store.saveAll(data);
      await _saveState(st);
      // Auch ohne eigene Änderung melden: Die frisch geladenen Daten können
      // Änderungen eines anderen Tabs enthalten, der sie schon gespeichert hat.
      onRemoteData?.call(data);
      return st.pending.isNotEmpty;
    });
    if (pushNeeded) _schedulePush();
  }

  Future<void> _onSynced(int gen, int headSeq) async {
    if (gen != _generation) return;
    final st = await _loadState();
    if (st == null) return;
    if (headSeq < st.seq) {
      // Der Server kennt weniger als wir (z. B. Datenbank neu aufgesetzt):
      // alles erneut hochladen und vollständig neu abgleichen.
      await _store.exclusive(() async {
        final s = await _loadState();
        if (s == null) return;
        s.resetRemote();
        await _saveState(s);
      });
      _onClosed(gen, null);
      return;
    }
    _live = true;
    _attempt = 0;
    error = null;
    status = SyncStatus.online;
    _notify();
    _schedulePush();
  }

  void _schedulePush() {
    if (!_live || _inflight != null) return;
    final gen = _generation;
    _enqueue(() => _push(gen));
  }

  Future<void> _push(int gen) async {
    if (gen != _generation || !_live || _inflight != null) return;
    final st = await _loadState();
    if (st == null) return;
    final names = st.pending.take(_maxPerPush).toList();
    if (names.isEmpty) return;
    final crypto = _crypto!;
    final wire = <WireRecord>[];
    final sent = <(String, int)>[];
    for (final name in names) {
      final key = await crypto.recordKey(name);
      final data = await crypto.encrypt(utf8.encode(st.payload(name)), key);
      wire.add(WireRecord(key, data));
      sent.add((name, st.records[name]!.modified));
    }
    if (gen != _generation || _channel == null) return;
    final reqId = ++_reqId;
    _inflight = (reqId: reqId, sent: sent);
    _channel!.sink.add(encodePush(reqId, wire));
  }

  Future<void> _onAck(int gen, int reqId, int firstSeq) async {
    final inflight = _inflight;
    if (gen != _generation || inflight == null || inflight.reqId != reqId) {
      return;
    }
    _inflight = null;
    final more = await _store.exclusive(() async {
      final st = await _loadState();
      if (st == null) return false;
      st.acked(inflight.sent);
      // Alle kleineren Sequenznummern hat der Server vor dem ACK zugestellt.
      st.seq = max(st.seq, firstSeq + inflight.sent.length - 1);
      await _saveState(st);
      return st.pending.isNotEmpty;
    });
    if (more) _schedulePush();
  }

  Future<void> _onVaultDeleted() async {
    final requested = _deleteDone;
    _deleteDone = null;
    _generation++;
    _retryTimer?.cancel();
    _closeChannel();
    await _store.saveSyncState(null);
    _reset();
    if (requested != null) {
      requested.complete();
    } else {
      notice = 'Die Synchronisation wurde auf einem anderen Gerät beendet '
          'und die Daten auf dem Server gelöscht. Die Daten auf diesem Gerät '
          'bleiben erhalten.';
      _notify();
    }
  }
}
