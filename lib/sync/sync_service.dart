import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models.dart';
import 'hosting_server.dart';
import 'network_events.dart';
import 'sync_crypto.dart';
import 'sync_protocol.dart';
import 'sync_records.dart';
import 'tab_coordination.dart';

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

enum SyncStatus {
  off,
  connecting,
  online,
  offline,

  /// Im Browser: Ein anderer Tab hält die Verbindung, dieser Tab bekommt
  /// dessen Änderungen über den gemeinsamen Speicher.
  otherTab,
}

/// Optionale Synchronisation über einen AnTaTime-Server.
///
/// Ablauf: Nach dem Verbinden sendet die App HELLO mit der zuletzt
/// übernommenen Sequenznummer; der Server schickt alle neueren Datensätze und
/// danach SYNCED. Ab dann kommen Änderungen anderer Geräte sofort an, eigene
/// Änderungen werden als PUSH gesendet. Alles ist Ende-zu-Ende-verschlüsselt
/// (siehe [SyncCrypto]).
class SyncService extends ChangeNotifier {
  SyncService(
    this._store, {
    this.onRemoteData,
    Stream<void> Function()? networkChanges,
    FutureOr<void Function()> Function(String name)? leaderLock,
  })  : _networkChanges = networkChanges ?? platformNetworkChanges,
        _leaderLock = leaderLock ?? acquireSyncLeadership;

  /// Standard-Server, z. B. `flutter build web --dart-define=SYNC_URL=…`.
  static const defaultUrl = String.fromEnvironment('SYNC_URL');

  /// Vorschlag für die Einrichtung: der beim Build festgelegte Server, sonst
  /// der Server, der diese Web-App ausgeliefert hat.
  static String get suggestedUrl =>
      defaultUrl.isNotEmpty ? defaultUrl : (hostingServerUrl() ?? '');

  static const _maxPerPush = 200;

  /// Ohne Daten vom Server wird nach dieser Zeit ein PING gesendet …
  static const _pingAfter = Duration(seconds: 10);

  /// … und ohne Antwort darauf die Verbindung aufgegeben.
  static const _probeTimeout = Duration(seconds: 6);
  static const _deadAfter = Duration(seconds: 25);
  static const _checkEvery = Duration(seconds: 2);

  /// Erst nach so langer stabiler Verbindung beginnt der Backoff von vorn.
  static const _stableAfter = Duration(seconds: 60);

  /// So lange erscheint eine Unterbrechung noch nicht als „Offline“.
  static const offlineGrace = Duration(seconds: 5);

  /// War die App länger im Hintergrund, ist die Verbindung meist tot
  /// (Energiesparen, NAT-Timeouts): beim Zurückkehren gleich neu verbinden.
  static const _reconnectAfterPause = Duration(seconds: 30);
  static const _backoff = [1, 2, 5, 10, 20, 30];

  /// Server ablehnend wegen Limits: nicht sofort erneut versuchen.
  static const _limitedRetry = Duration(seconds: 60);

  /// Fehler, die sich nicht von selbst beheben (Kontingent voll, zu alte App).
  static const _permanentRetry = Duration(minutes: 5);
  static const _leaderLockName = 'antatime-sync-leader';

  final SyncStore _store;
  final Stream<void> Function() _networkChanges;
  final FutureOr<void Function()> Function(String name) _leaderLock;

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

  /// Status für die Anzeige: Kurze Unterbrechungen, die sich gleich von
  /// selbst beheben, erscheinen als „Verbinde …“ statt als „Offline“.
  SyncStatus get displayStatus {
    final lost = _onlineLostAt;
    if (status == SyncStatus.offline &&
        lost != null &&
        DateTime.now().difference(lost) < offlineGrace) {
      return SyncStatus.connecting;
    }
    return status;
  }

  SyncCrypto? _crypto;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  int _generation = 0;
  bool _live = false;
  int _attempt = 0;
  Timer? _retryTimer;
  Timer? _pingTimer;
  Timer? _stableTimer;
  Timer? _graceTimer;
  DateTime _lastRx = DateTime.now();

  /// Zeitpunkt des unbeantworteten PINGs, `null` = keiner offen.
  DateTime? _probeSentAt;

  /// Fehlercode, den der Server vor dem Trennen geschickt hat.
  int? _serverErrorCode;

  /// Seit wann die Verbindung fehlt (für [displayStatus]).
  DateTime? _onlineLostAt;
  DateTime? _pausedAt;
  StreamSubscription<void>? _netSub;
  void Function()? _releaseLeader;
  int _leaderRequest = 0;
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
      final pending = await _store.exclusive(() async {
        final data = await _store.load();
        final st = await _loadState();
        if (st == null) return false;
        if (st.diffLocal(recordsOf(data)) > 0) await _saveState(st);
        // Auch ohne neue Änderung: Ein anderer Tab kann Änderungen vorgemerkt
        // haben, die nur dieser Tab (mit der Verbindung) senden kann.
        return st.pending.isNotEmpty;
      });
      if (pending) _schedulePush();
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
    _dropLeadership();
    if (enabled) _reset();
  }

  /// App geht in den Hintergrund.
  void pause() {
    _pausedAt ??= DateTime.now();
  }

  /// App kommt in den Vordergrund: Verbindung prüfen bzw. wiederherstellen.
  void resume() {
    final paused = _pausedAt;
    _pausedAt = null;
    if (!enabled) return;
    final longAway = paused != null &&
        DateTime.now().difference(paused) > _reconnectAfterPause;
    if (status == SyncStatus.offline ||
        (longAway &&
            (status == SyncStatus.online || status == SyncStatus.connecting))) {
      _reconnectNow();
    } else if (status == SyncStatus.online) {
      _probe();
    }
  }

  /// Netzwerk gewechselt: Eine offene Verbindung ist danach oft tot, eine
  /// fehlende klappt jetzt vielleicht wieder.
  void networkChanged() {
    if (!enabled) return;
    if (status == SyncStatus.offline && _serverErrorCode == null) {
      _reconnectNow();
    } else if (status == SyncStatus.online) {
      _probe();
    }
  }

  void _reconnectNow() {
    _retryTimer?.cancel();
    _attempt = 0;
    if (status == SyncStatus.online) _onlineLostAt = DateTime.now();
    _connect();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _graceTimer?.cancel();
    _netSub?.cancel();
    _netSub = null;
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
    _onlineLostAt = DateTime.now();
    _listenNetwork();
    _becomeLeaderAndConnect();
  }

  /// Verbindet, sobald dieser Tab die Verbindung halten darf (nativ sofort).
  void _becomeLeaderAndConnect() {
    _dropLeadership();
    final request = _leaderRequest;
    final lock = _leaderLock(_leaderLockName);
    if (lock is! Future<void Function()>) {
      _releaseLeader = lock;
      _connect();
      return;
    }
    status = SyncStatus.otherTab;
    _notify();
    lock.then((release) {
      if (request != _leaderRequest || !enabled || _disposed) {
        release();
        return;
      }
      _releaseLeader = release;
      _onlineLostAt = DateTime.now();
      _connect();
    });
  }

  void _dropLeadership() {
    _leaderRequest++;
    _releaseLeader?.call();
    _releaseLeader = null;
  }

  void _listenNetwork() {
    if (_netSub != null) return;
    try {
      _netSub = _networkChanges().listen(
        (_) => networkChanged(),
        onError: (Object e) => debugPrint('Netzwerkstatus nicht verfügbar: $e'),
      );
    } catch (e) {
      debugPrint('Netzwerkstatus nicht verfügbar: $e');
    }
  }

  void _reset() {
    url = null;
    code = null;
    _crypto = null;
    error = null;
    status = SyncStatus.off;
    _graceTimer?.cancel();
    _netSub?.cancel();
    _netSub = null;
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
    _serverErrorCode = null;
    _lastRx = DateTime.now();
    _notify();
    try {
      final ch = WebSocketChannel.connect(wsUri(url!));
      _channel = ch;
      await ch.ready.timeout(const Duration(seconds: 15));
      if (gen != _generation) return;
      _lastRx = DateTime.now();
      _sub = ch.stream.listen(
        (msg) => _onFrame(gen, msg),
        onDone: () => _onClosed(gen, _closeText(ch)),
        onError: (Object e) => _onClosed(gen, e),
        cancelOnError: true,
      );
      final st = await _loadState();
      if (gen != _generation || st == null) return;
      ch.sink.add(encodeHello(_crypto!.vaultId, st.seq));
      _pingTimer = Timer.periodic(_checkEvery, (_) => _checkAlive());
    } catch (e) {
      _onClosed(gen, e);
    }
  }

  static String _closeText(WebSocketChannel ch) {
    final reason = ch.closeReason;
    if (reason != null && reason.isNotEmpty) return reason;
    final code = ch.closeCode;
    return code == null
        ? 'Verbindung getrennt'
        : 'Verbindung getrennt (Code $code)';
  }

  /// Erkennt tote Verbindungen: Nach [_pingAfter] ohne Daten wird gepingt,
  /// bleibt die Antwort [_probeTimeout] lang aus, wird neu verbunden.
  void _checkAlive() {
    if (_sub == null) return;
    final now = DateTime.now();
    final probe = _probeSentAt;
    if ((probe != null && now.difference(probe) > _probeTimeout) ||
        now.difference(_lastRx) > _deadAfter) {
      _onClosed(_generation, 'Keine Antwort vom Server');
    } else if (probe == null && now.difference(_lastRx) > _pingAfter) {
      _probe();
    }
  }

  /// Sendet einen PING; jede Nachricht vom Server gilt als Antwort.
  void _probe() {
    final ch = _channel;
    if (ch == null || _sub == null) return;
    _probeSentAt ??= DateTime.now();
    ch.sink.add(pingFrame);
  }

  void _closeChannel() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    _probeSentAt = null;
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
    final wasOnline = status == SyncStatus.online;
    final serverError = _serverErrorCode;
    _closeChannel();
    if (!enabled || _disposed) return;
    if (wasOnline) _onlineLostAt = DateTime.now();
    status = SyncStatus.offline;
    // Die Fehlermeldung des Servers ist aussagekräftiger als der Close-Grund.
    if (serverError == null && reason != null) error = _describe(reason);
    _notify();
    // Nach Ablauf der Schonfrist von „Verbinde …“ auf „Offline“ wechseln.
    _graceTimer?.cancel();
    _graceTimer = Timer(offlineGrace, _notify);
    final delay = retryDelay(_attempt, serverError, reason);
    _attempt++;
    _retryTimer?.cancel();
    _retryTimer =
        Timer(delay + Duration(milliseconds: Random().nextInt(500)), () {
      if (enabled && status == SyncStatus.offline) _connect();
    });
  }

  /// Wartezeit bis zum nächsten Verbindungsversuch.
  @visibleForTesting
  static Duration retryDelay(int attempt, int? serverError, Object? reason) {
    switch (serverError) {
      case SyncErrorCode.unsupportedVersion ||
            SyncErrorCode.tooLarge ||
            SyncErrorCode.quotaExceeded:
        return _permanentRetry;
      case SyncErrorCode.badRequest ||
            SyncErrorCode.rateLimited ||
            SyncErrorCode.tooManyConnections:
        return _limitedRetry;
    }
    final s = reason?.toString() ?? '';
    if (s.contains('429') || s.contains('503')) return _limitedRetry;
    return Duration(seconds: _backoff[min(attempt, _backoff.length - 1)]);
  }

  static String _describe(Object e) {
    final s = e.toString();
    if (s.contains('429')) {
      return 'Zu viele Verbindungen von dieser Adresse, neuer Versuch in einer Minute';
    }
    if (s.contains('503')) return 'Server ausgelastet, neuer Versuch in einer Minute';
    if (s.contains('SocketException') ||
        s.contains('WebSocketChannelException') ||
        s.contains('TimeoutException')) {
      return 'Server nicht erreichbar';
    }
    return s;
  }

  Future<void> _shutdown() async {
    _generation++;
    _retryTimer?.cancel();
    _closeChannel();
    _dropLeadership();
    await _chain;
  }

  // ---------------------------------------------------------------------------
  // Nachrichten

  void _onFrame(int gen, dynamic msg) {
    if (gen != _generation) return;
    _lastRx = DateTime.now();
    _probeSentAt = null;
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
      case ErrorMessage(:final code, :final message):
        _serverErrorCode = code;
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
    error = null;
    status = SyncStatus.online;
    _onlineLostAt = null;
    // Den Backoff erst nach stabiler Verbindung zurücksetzen: Trennt der
    // Server gleich wieder (z. B. beim nächsten PUSH), soll der Client nicht
    // im Sekundentakt neu verbinden.
    _stableTimer?.cancel();
    _stableTimer = Timer(_stableAfter, () => _attempt = 0);
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
    _attempt = 0;
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
    _dropLeadership();
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
