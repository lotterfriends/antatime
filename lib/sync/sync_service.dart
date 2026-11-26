import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../format.dart';
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

/// Ergebnis der regelmäßigen Verbindungsprüfung (siehe
/// [SyncService.aliveCheck]).
enum AliveCheck { ok, probe, dead }

enum SyncStatus {
  off,
  connecting,
  online,
  offline,

  /// Im Browser: Ein anderer Tab hält die Verbindung, dieser Tab bekommt
  /// dessen Änderungen über den gemeinsamen Speicher.
  otherTab,
}

/// Der Server lässt die App nicht herein – behebt sich nicht von selbst.
enum SyncProblem {
  /// Der Server hat die maximale Anzahl an Nutzern erreicht.
  serverFull,

  /// Der Server verlangt einen Server-Schlüssel, es ist keiner eingetragen.
  keyRequired,

  /// Der eingetragene Server-Schlüssel ist falsch.
  keyWrong,

  /// Ein Server-Schlüssel ist eingetragen, der Server verwendet aber keinen.
  keyUnused,

  /// Der Server konnte sich nicht mit dem Schlüssel ausweisen.
  serverUnverified,

  /// Der Speicherplatz (des Sync-Codes oder des Servers) ist voll.
  quotaFull;

  /// Hat mit dem Server-Schlüssel zu tun (in den Einstellungen zu beheben).
  bool get isKey =>
      this == keyRequired ||
      this == keyWrong ||
      this == keyUnused ||
      this == serverUnverified;

  String get title => switch (this) {
        serverFull => 'Server ist voll',
        keyRequired => 'Server-Schlüssel erforderlich',
        keyWrong => 'Server-Schlüssel ist falsch',
        keyUnused => 'Server verwendet keinen Schlüssel',
        serverUnverified => 'Server nicht bestätigt',
        quotaFull => 'Speicherplatz ist voll',
      };

  String get text => switch (this) {
        serverFull =>
          'Dieser Server hat die maximale Anzahl an Nutzern erreicht und '
              'nimmt keine neuen Sync-Codes an. Bitte den Betreiber fragen '
              'oder einen anderen Server verwenden.',
        keyRequired =>
          'Dieser Server verlangt einen Server-Schlüssel. Du bekommst ihn '
              'vom Betreiber des Servers.',
        keyWrong =>
          'Der Server hat den eingetragenen Server-Schlüssel abgelehnt. '
              'Bitte den Schlüssel prüfen.',
        keyUnused =>
          'Es ist ein Server-Schlüssel eingetragen, dieser Server verwendet '
              'aber keinen. Bitte die Adresse prüfen oder den Schlüssel '
              'entfernen.',
        serverUnverified =>
          'Der Server konnte sich nicht mit dem Server-Schlüssel ausweisen. '
              'Bitte Adresse und Schlüssel prüfen.',
        quotaFull => 'Der Speicherplatz auf dem Server ist voll.',
      };

  static SyncProblem? ofCode(int? code) => switch (code) {
        SyncErrorCode.serverFull => serverFull,
        SyncErrorCode.authRequired => keyRequired,
        SyncErrorCode.authFailed => keyWrong,
        SyncErrorCode.keyUnused => keyUnused,
        SyncErrorCode.serverUnverified => serverUnverified,
        SyncErrorCode.quotaExceeded => quotaFull,
        _ => null,
      };
}

/// Ergebnis von [SyncService.check].
class SyncCheck {
  const SyncCheck({this.problem, this.message, this.unreachable = false});

  /// Der Server hat abgelehnt.
  final SyncProblem? problem;

  /// Meldung für die Anzeige; `null` = alles in Ordnung.
  final String? message;

  /// Der Server war nicht erreichbar (kein Urteil möglich).
  final bool unreachable;

  bool get ok => message == null;
}

/// Anmeldung an Servern mit Server-Schlüssel, vor dem HELLO.
///
/// Mit Schlüssel sendet der Client zuerst ein PING: Ein Server mit Anmeldung
/// hat dann schon eine CHALLENGE geschickt; kommt stattdessen zuerst PONG,
/// verwendet er keinen Schlüssel.
class ServerLogin {
  ServerLogin(this.serverKey) : ready = serverKey == null;

  final String? serverKey;

  /// HELLO darf gesendet werden.
  bool ready;
  bool _challenged = false;
  List<int>? _proof;

  /// Zuerst zu sendende Nachricht (`null` ohne Schlüssel).
  Uint8List? get opening => serverKey == null ? null : pingFrame;

  /// Verarbeitet CHALLENGE, AUTH_OK und PONG. Liefert `null`, solange nichts
  /// zu tun ist, `0`, sobald HELLO gesendet werden darf, sonst den Fehler
  /// (siehe [SyncErrorCode]).
  Future<int?> handle(ServerMessage m, void Function(Uint8List) send) async {
    final key = serverKey;
    if (key == null || ready) return null;
    switch (m) {
      case ChallengeMessage(:final nonce):
        if (_challenged) return null;
        _challenged = true;
        final a = await ServerKey.answer(key, nonce);
        _proof = a.proof;
        send(encodeAuth(a.ephPub, a.mac));
      case AuthOkMessage(:final proof):
        final expected = _proof;
        if (expected == null) return null;
        if (!ServerKey.sameBytes(expected, proof)) {
          return SyncErrorCode.serverUnverified;
        }
        ready = true;
        return 0;
      case PongMessage():
        if (!_challenged) return SyncErrorCode.keyUnused;
      default:
        break;
    }
    return null;
  }
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
    this.nativeChanges,
  })  : _networkChanges = networkChanges ?? platformNetworkChanges,
        _leaderLock = leaderLock ?? acquireSyncLeadership;

  /// Liefert (und vergisst) die Zeitpunkte nativer Änderungen an
  /// Arbeitszeiten (Arbeitszeit-ID → ms), siehe [SyncState.diffLocal].
  final Future<Map<String, int>> Function()? nativeChanges;

  Future<Map<String, int>> _madeAt() async {
    final f = nativeChanges;
    if (f == null) return const {};
    try {
      return {for (final e in (await f()).entries) 's:${e.key}': e.value};
    } catch (e) {
      debugPrint('Sync: Zeitpunkte nativer Änderungen nicht lesbar: $e');
      return const {};
    }
  }

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

  /// Server-Schlüssel (normalisiert), wenn einer eingetragen ist.
  String? serverKey;

  /// Letzter Verbindungsfehler (für die Anzeige).
  String? error;

  /// Der Server lässt die App nicht herein (voll, Server-Schlüssel) – für
  /// eine deutliche Meldung statt „Offline“.
  SyncProblem? get problem => status == SyncStatus.offline
      ? SyncProblem.ofCode(_serverErrorCode)
      : null;

  /// Einmaliger Hinweis, z. B. wenn ein anderes Gerät den Sync beendet hat.
  String? notice;

  bool get enabled => code != null;

  /// Größter Datensatz, den der Server annimmt (verschlüsselt, Standard
  /// von MAX_RECORD_BYTES).
  static const maxRecordBytes = 16 * 1024;

  /// Hinweis zu Datensätzen, die zu groß für die Übertragung sind.
  @visibleForTesting
  static String tooLargeNotice(List<String> names) {
    final what = names.any((n) => n.startsWith('s:'))
        ? 'eine Arbeitszeit'
        : names.any((n) => n.startsWith('a:'))
            ? 'eine Abwesenheit'
            : 'eine Einstellung';
    return 'Mindestens $what ist zu groß für die Synchronisation (z. B. eine '
        'sehr lange Notiz) und wird nicht übertragen. Bitte die Notiz kürzen.';
  }

  /// Hinweis, wenn beim Beitreten die auf diesem Gerät laufende
  /// Zeiterfassung (seit [start]) verworfen wurde, weil auf einem anderen
  /// Gerät zu dieser Zeit bereits erfasst wurde. Die App kann das nicht von
  /// einem doppelten Start unterscheiden, also muss der Nutzer prüfen.
  static String joinRunningDroppedNotice(DateTime start, DateTime now) {
    final since = dayOf(start) == dayOf(now)
        ? formatTime(start)
        : '${formatDateShort(start)}, ${formatTime(start)}';
    final day = dayOf(start) == dayOf(now)
        ? 'von heute'
        : 'vom ${formatDateShort(start)}';
    return 'Auf diesem Gerät lief beim Beitreten eine Zeiterfassung seit '
        '$since Uhr. Sie wurde verworfen, weil auf einem anderen Gerät zu '
        'dieser Zeit bereits erfasst wurde. Bitte die Arbeitszeiten $day '
        'prüfen und fehlende Zeit nachtragen.';
  }

  /// Hinweis, wenn eine veraltete Arbeitszeit (seit [start]) beim Abgleich
  /// beendet wurde, weil seither – an späteren Tagen – weitere Arbeitszeiten
  /// erfasst wurden (siehe [AppData.resolveOverlaps]). Ihr tatsächliches
  /// Ende kennt die App nicht, also muss der Nutzer prüfen.
  static String staleEndedNotice(DateTime start, DateTime end) {
    String at(DateTime t) => '${formatDateShort(t)}, ${formatTime(t)} Uhr';
    return 'Die Zeiterfassung vom ${at(start)} lief auf einem Gerät noch '
        'weiter, obwohl danach bereits weitere Arbeitszeiten erfasst wurden '
        '(z. B. ein lange nicht synchronisiertes Gerät). Damit sie diese nicht '
        'überschreibt, wurde sie zum Beginn der nächsten Arbeitszeit beendet '
        '(${at(end)}). Bitte ihr Ende prüfen und anpassen.';
  }

  /// Wie weit die Uhr dieses Geräts von der des Servers abweicht (positiv =
  /// geht vor); `null` = unbekannt. Beim Verbinden ermittelt.
  Duration? clockOffset;

  /// Ab dieser Abweichung wird gewarnt: Welche Zeiterfassung zuerst
  /// gestartet wurde, entscheiden die Uhren der Geräte.
  static const clockTolerance = Duration(minutes: 2);

  /// Hinweis, wenn die Uhr dieses Geräts deutlich falsch geht.
  String? get clockWarning {
    final o = clockOffset;
    if (o == null || o.abs() < clockTolerance) return null;
    final min = o.inMinutes.abs();
    return 'Die Uhr dieses Geräts geht etwa $min Minuten '
        '${o.isNegative ? 'nach' : 'vor'}. Bitte die Uhrzeit automatisch '
        'stellen lassen – sonst stimmen die erfassten Zeiten nicht und beim '
        'Abgleich kann die falsche Zeiterfassung als zuerst gestartet gelten.';
  }

  /// Status für die Anzeige: Kurze Unterbrechungen, die sich gleich von
  /// selbst beheben, erscheinen als „Verbinde …“ statt als „Offline“.
  SyncStatus get displayStatus {
    final lost = _onlineLostAt;
    if (status == SyncStatus.offline &&
        problem == null &&
        lost != null &&
        DateTime.now().difference(lost) < offlineGrace) {
      return SyncStatus.connecting;
    }
    return status;
  }

  SyncCrypto? _crypto;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  /// Anmeldung der laufenden Verbindung und das HELLO, das danach gesendet
  /// wird (`null`, solange der gespeicherte Stand noch geladen wird).
  ServerLogin? _login;
  Uint8List? _pendingHello;
  bool _helloSent = false;
  int _generation = 0;
  bool _live = false;

  /// Dieses Gerät hat das Löschen der Daten auf dem Server angefordert.
  bool _deleteRequested = false;

  /// Beim Beitreten: die Arbeitszeit, die auf diesem Gerät gerade läuft –
  /// bis zum ersten vollständigen Abgleich (siehe [_onSynced]).
  String? _joinRunning;
  int _attempt = 0;
  Timer? _retryTimer;
  Timer? _pingTimer;
  Timer? _stableTimer;
  Timer? _graceTimer;
  DateTime _lastRx = DateTime.now();
  DateTime _lastCheck = DateTime.now();

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

  /// Wartet höchstens [timeout], bis der Stand des Servers übernommen ist
  /// (sofort zurück, wenn der Sync aus ist). Z. B. vor dem automatischen
  /// Start der Zeiterfassung, damit eine auf einem anderen Gerät bereits
  /// laufende Zeit erkannt wird.
  Future<void> waitUntilSynced(Duration timeout) async {
    bool ready() => !enabled || status == SyncStatus.online;
    if (ready()) return;
    final done = Completer<void>();
    void check() {
      if (ready() && !done.isCompleted) done.complete();
    }

    addListener(check);
    try {
      await done.future.timeout(timeout, onTimeout: () {});
    } finally {
      removeListener(check);
    }
  }

  /// Neu verbinden und auf den Stand des Servers warten (höchstens
  /// [timeout]) – für den regelmäßigen Abgleich im Hintergrund, nach dem die
  /// bestehende Verbindung oft tot ist, ohne dass es aufgefallen wäre.
  Future<void> syncNow(Duration timeout) async {
    if (!enabled) return;
    // Nach einem Serverfehler (z. B. Speicher voll) gilt dessen Wartezeit.
    if (_serverErrorCode != null) return;
    _reconnectNow();
    await waitUntilSynced(timeout);
  }

  /// Sync einschalten. `join == false`: neuer Code, alle lokalen Daten werden
  /// hochgeladen. `join == true`: bestehender Code, die Daten werden
  /// zusammengeführt (bei Konflikten gewinnt der Server-Stand).
  Future<void> enable(
      {required String url,
      required String code,
      required bool join,
      String? serverKey}) async {
    await _shutdown();
    final st = await _store.exclusive(() async {
      final data = await _store.load();
      final st = SyncState(url: url, code: code, serverKey: serverKey);
      final current = recordsOf(data);
      if (join) {
        st.seedForJoin(current);
        _joinRunning = data.running?.id;
      } else {
        st.diffLocal(current);
      }
      await _saveState(st);
      return st;
    });
    notice = null;
    await _activate(st);
  }

  /// Server-Schlüssel eintragen, ändern oder (mit `null`) entfernen und
  /// gleich neu verbinden.
  Future<void> setServerKey(String? key) async {
    if (!enabled) return;
    await _enqueue(() => _store.exclusive(() async {
          final st = await _loadState();
          if (st == null) return;
          st.serverKey = key;
          await _saveState(st);
        }));
    if (!enabled) return;
    serverKey = key;
    _notify();
    // Im Browser verbindet nur der Tab, der die Verbindung hält; er bemerkt
    // die Änderung über den gemeinsamen Speicher.
    if (_releaseLeader != null) _reconnectNow();
  }

  /// Prüft vor dem Einrichten, ob der Server diesen Zugang annimmt: Adresse,
  /// Server-Schlüssel und – bei einem neuen Code – ob noch Platz ist.
  static Future<SyncCheck> check({
    required String url,
    required String code,
    String? serverKey,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    const unreachable = SyncCheck(
        message: 'Server nicht erreichbar', unreachable: true);
    WebSocketChannel? ch;
    StreamSubscription<dynamic>? sub;
    try {
      final crypto = await SyncCrypto.fromCode(code);
      final channel = ch = WebSocketChannel.connect(wsUri(url));
      await channel.ready.timeout(timeout);
      final done = Completer<SyncCheck>();
      void finish(SyncCheck r) {
        if (!done.isCompleted) done.complete(r);
      }

      SyncCheck failed(int code, String message) {
        final p = SyncProblem.ofCode(code);
        return SyncCheck(
            problem: p,
            message: p == null || p == SyncProblem.quotaFull
                ? (message.isEmpty ? 'Der Server hat abgelehnt' : message)
                : p.text);
      }

      final login = ServerLogin(serverKey);
      // Mit einer sehr großen Sequenznummer schickt der Server keine Daten,
      // nur SYNCED – oder den Fehler.
      void hello() =>
          channel.sink.add(encodeHello(crypto.vaultId, _noCatchUpSeq));
      SyncCheck? rejected;
      sub = channel.stream.listen(
        (msg) async {
          final ServerMessage m;
          try {
            m = decodeServerMessage(_frameBytes(msg));
          } on FormatException {
            return;
          }
          switch (m) {
            case ErrorMessage(:final code, :final message):
              // Danach trennt der Server.
              finish(rejected = failed(code, message));
            case VaultDeletedMessage():
              finish(const SyncCheck(
                  message: 'Dieser Sync-Code wurde gelöscht und ist nicht '
                      'mehr verwendbar.'));
            case SyncedMessage() || ChangesMessage():
              finish(const SyncCheck());
            default:
              final step = await login.handle(m, channel.sink.add);
              if (step == 0) {
                hello();
              } else if (step != null) {
                finish(failed(step, ''));
              }
          }
        },
        onDone: () => finish(rejected ?? unreachable),
        onError: (Object _) => finish(unreachable),
        cancelOnError: true,
      );
      final opening = login.opening;
      if (opening != null) {
        channel.sink.add(opening);
      } else {
        hello();
      }
      return await done.future.timeout(timeout, onTimeout: () => unreachable);
    } catch (e) {
      debugPrint('Sync-Prüfung fehlgeschlagen: $e');
      return unreachable;
    } finally {
      await sub?.cancel();
      unawaited(ch?.sink.close());
    }
  }

  /// 2^52 (als Zahl, weil `<<` im Browser nur 32 Bit kennt).
  static const _noCatchUpSeq = 4503599627370496;

  static Uint8List _frameBytes(dynamic msg) {
    if (msg is Uint8List) return msg;
    if (msg is ByteBuffer) return msg.asUint8List();
    if (msg is List<int>) return Uint8List.fromList(msg);
    throw const FormatException('Keine Binärnachricht');
  }

  /// Sync auf diesem Gerät beenden. Mit [deleteRemote] werden zusätzlich alle
  /// Daten auf dem Server gelöscht und der Code ungültig – die anderen Geräte
  /// beenden den Sync dann ebenfalls. Gibt `false` zurück, wenn das Löschen
  /// mangels Verbindung nicht möglich war.
  Future<bool> disable({bool deleteRemote = false}) async {
    if (deleteRemote) {
      if (!_live) return false;
      // Auch wenn die Bestätigung zu spät kommt: Dieses Gerät hat gelöscht
      // und soll nicht „auf einem anderen Gerät beendet“ melden.
      _deleteRequested = true;
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
        if (st.diffLocal(recordsOf(data), null, await _madeAt()) > 0) {
          await _saveState(st);
        }
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
    if (stored?.code == code) {
      // Server-Schlüssel in einem anderen Tab geändert: neu anmelden.
      if (stored != null && stored.serverKey != serverKey) {
        serverKey = stored.serverKey;
        _notify();
        if (_releaseLeader != null) _reconnectNow();
      }
      return stored != null;
    }
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
    // Nach einem Serverfehler (z. B. Speicher voll, Version) gilt dessen
    // Wartezeit – nicht bei jedem Öffnen der App gleich erneut versuchen.
    if ((status == SyncStatus.offline && _serverErrorCode == null) ||
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
    serverKey = st.serverKey;
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
    _joinRunning = null;
    url = null;
    code = null;
    serverKey = null;
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
      final login = _login = ServerLogin(serverKey);
      _sub = ch.stream.listen(
        (msg) => _onFrame(gen, msg),
        onDone: () => _onClosed(gen, _closeText(ch)),
        onError: (Object e) => _onClosed(gen, e),
        cancelOnError: true,
      );
      final st = await _loadState();
      if (gen != _generation) return;
      if (st == null || st.code != code) {
        // In einem anderen Tab beendet oder umgestellt: nachziehen statt die
        // Verbindung ohne HELLO offen zu lassen (der Server würde sie nach
        // einer Weile trennen, und es ginge von vorn los).
        _closeChannel();
        await _followStoredState(st);
        return;
      }
      if (st.serverKey != serverKey) {
        // In einem anderen Tab geändert: mit dem neuen Schlüssel anmelden.
        serverKey = st.serverKey;
        _reconnectNow();
        return;
      }
      final opening = login.opening;
      if (opening != null) ch.sink.add(opening);
      _pendingHello = encodeHello(_crypto!.vaultId, st.seq);
      _maybeHello();
      _lastCheck = DateTime.now();
      _pingTimer = Timer.periodic(_checkEvery, (_) => _checkAlive());
    } catch (e) {
      _onClosed(gen, e);
    }
  }

  /// Sendet HELLO, sobald der Stand geladen und die Anmeldung erledigt ist.
  void _maybeHello() {
    final hello = _pendingHello;
    if (hello == null || _helloSent || !(_login?.ready ?? false)) return;
    _helloSent = true;
    _channel?.sink.add(hello);
  }

  /// CHALLENGE, AUTH_OK oder PONG während der Anmeldung.
  void _onLogin(int gen, ServerMessage m) {
    final login = _login;
    if (login == null || login.ready) return;
    login.handle(m, (frame) {
      if (gen == _generation) _channel?.sink.add(frame);
    }).then((step) {
      if (gen != _generation || step == null) return;
      if (step == 0) {
        _maybeHello();
      } else {
        _rejected(gen, step);
      }
    }, onError: (Object e) {
      debugPrint('Sync: Anmeldung fehlgeschlagen: $e');
      if (gen == _generation) _rejected(gen, SyncErrorCode.authFailed);
    });
  }

  /// Die App hat selbst festgestellt, dass dieser Server nicht passt.
  void _rejected(int gen, int code) {
    _serverErrorCode = code;
    error = SyncProblem.ofCode(code)?.text;
    _onClosed(gen, null);
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
    final check = aliveCheck(
        now: now,
        lastCheck: _lastCheck,
        lastRx: _lastRx,
        probeSentAt: _probeSentAt);
    _lastCheck = now;
    switch (check) {
      case AliveCheck.ok:
        break;
      case AliveCheck.probe:
        _probe();
      case AliveCheck.dead:
        _onClosed(_generation, 'Keine Antwort vom Server');
    }
  }

  /// Entscheidet bei jeder Prüfung, ob die Verbindung noch lebt.
  ///
  /// Kam der Timer deutlich zu spät – im Browser drosselt Chrome Timer in
  /// Hintergrund-Tabs auf einmal pro Minute, auf dem Desktop nach dem
  /// Ruhezustand –, sagt die Zeit seit der letzten Nachricht nichts über die
  /// Verbindung aus. Dann wird erst nachgefragt (PING) statt getrennt.
  /// Ein unbeantworteter PING bedeutet dagegen immer eine tote Verbindung:
  /// Nachrichten kommen auch in Hintergrund-Tabs sofort an, nur Timer
  /// werden gedrosselt.
  @visibleForTesting
  static AliveCheck aliveCheck({
    required DateTime now,
    required DateTime lastCheck,
    required DateTime lastRx,
    DateTime? probeSentAt,
  }) {
    if (probeSentAt != null) {
      return now.difference(probeSentAt) > _probeTimeout
          ? AliveCheck.dead
          : AliveCheck.ok;
    }
    if (now.difference(lastCheck) > _checkEvery * 3) return AliveCheck.probe;
    final idle = now.difference(lastRx);
    if (idle > _deadAfter) return AliveCheck.dead;
    if (idle > _pingAfter) return AliveCheck.probe;
    return AliveCheck.ok;
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
    _login = null;
    _pendingHello = null;
    _helloSent = false;
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
            SyncErrorCode.quotaExceeded ||
            SyncErrorCode.authRequired ||
            SyncErrorCode.authFailed ||
            SyncErrorCode.serverFull ||
            SyncErrorCode.keyUnused ||
            SyncErrorCode.serverUnverified:
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
    final ServerMessage m;
    try {
      m = decodeServerMessage(_frameBytes(msg));
    } on FormatException catch (e) {
      debugPrint('Sync: ungültige Nachricht: $e');
      return;
    }
    switch (m) {
      case ChangesMessage(:final records):
        _enqueue(() async {
          try {
            await _applyRemote(gen, records);
          } catch (e) {
            // Nicht übernommen (z. B. Speicher voll): Verbindung trennen,
            // bevor ein späteres CHANGES oder ACK die Sequenznummer darüber
            // hinweg hebt – beim nächsten HELLO kommen sie erneut.
            debugPrint('Sync: Änderungen nicht übernommen: $e');
            _onClosed(gen, 'Änderungen konnten nicht gespeichert werden');
          }
        });
      case SyncedMessage(:final headSeq, :final serverTime, :final epoch):
        if (serverTime != null) {
          clockOffset = Duration(
              milliseconds: DateTime.now().millisecondsSinceEpoch - serverTime);
        }
        _enqueue(() => _onSynced(gen, headSeq, epoch));
      case AckMessage(:final reqId, :final firstSeq):
        _enqueue(() => _onAck(gen, reqId, firstSeq));
      case PongMessage() || ChallengeMessage() || AuthOkMessage():
        _onLogin(gen, m);
      case VaultDeletedMessage():
        // Sofort, nicht erst in der Warteschlange: Sonst verbindet der Retry
        // nach dem Trennen des Servers neu und bekommt die Meldung erneut.
        _generation++;
        _retryTimer?.cancel();
        _enqueue(_onVaultDeleted);
      case ErrorMessage(:final code, :final message):
        _serverErrorCode = code;
        // Beim Speicherplatz sagt der Server genauer, was voll ist.
        final p = SyncProblem.ofCode(code);
        error = p == null || p == SyncProblem.quotaFull ? message : p.text;
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
      // Ein anderer Tab kann inzwischen einen anderen Code eingerichtet haben.
      if (st == null || st.code != code) return false;
      st.diffLocal(recordsOf(data), null, await _madeAt());
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
      // Beim Nachholen kommen die Änderungen in mehreren Teilen. Erst wenn
      // alles da ist (live), ist der Stand vollständig genug, um
      // Überschneidungen aufzulösen – sonst fehlt z. B. noch das Ende einer
      // Arbeitszeit aus einem späteren Teil. Nach dem Nachholen: _onSynced.
      if (_live &&
          decoded.any((d) => d.$2.startsWith('s:')) &&
          _resolveOverlaps(data, st)) {
        changed = true;
      }
      if (changed) await _store.saveAll(data);
      await _saveState(st);
      // Auch ohne eigene Änderung melden: Die frisch geladenen Daten können
      // Änderungen eines anderen Tabs enthalten, der sie schon gespeichert hat.
      if (!_disposed) onRemoteData?.call(data);
      return st.pending.isNotEmpty;
    });
    if (pushNeeded) _schedulePush();
  }

  Future<void> _onSynced(int gen, int headSeq, [int? epoch]) async {
    if (gen != _generation) return;
    final st = await _loadState();
    // Nach jedem Warten erneut prüfen: Die Verbindung kann inzwischen
    // getrennt worden sein – dann darf sie nicht wieder als online gelten.
    if (gen != _generation || st == null || st.code != code) return;
    // Der Server kennt weniger als wir (z. B. Datenbank neu aufgesetzt) oder
    // hat den Vault neu angelegt (z. B. nach Ablauf – die Sequenznummern
    // beginnen dann von vorn, und HELLO hätte Datensätze übersprungen):
    // alles erneut hochladen und vollständig neu abgleichen.
    final newVault = epoch != null && st.epoch != null && st.epoch != epoch;
    if (headSeq < st.seq || newVault) {
      await _store.exclusive(() async {
        final s = await _loadState();
        if (s == null) return;
        s
          ..resetRemote()
          ..epoch = epoch ?? s.epoch;
        await _saveState(s);
      });
      _onClosed(gen, null);
      return;
    }
    // Nachholen abgeschlossen: Überschneidungen jetzt auflösen – auch ältere,
    // die vor dieser App-Version entstanden sind.
    await _store.exclusive(() async {
      final data = await _store.load();
      final st = await _loadState();
      if (st == null || st.code != code) return;
      if (epoch != null) st.epoch = epoch;
      st.diffLocal(recordsOf(data), null, await _madeAt());
      final joinRunning = _joinRunning;
      _joinRunning = null;
      WorkSession? lost;
      if (_resolveOverlaps(data, st,
          onDropped: (s) => lost ??= s.id == joinRunning ? s : null)) {
        await _store.saveAll(data);
        if (!_disposed) onRemoteData?.call(data);
      }
      await _saveState(st);
      if (lost != null) {
        notice = joinRunningDroppedNotice(lost!.start, DateTime.now());
      }
    });
    if (gen != _generation) return;
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

  /// Überschneiden sich Arbeitszeiten (auf zwei Geräten gestartet), gewinnt
  /// die zuerst gestartete (siehe [AppData.resolveOverlaps]). Die Änderungen
  /// gehen an alle Geräte; die kommen unabhängig davon zum selben Ergebnis.
  ///
  /// Veraltete Arbeitszeiten werden dabei beendet statt zu gewinnen; darüber
  /// informiert ein Hinweis.
  bool _resolveOverlaps(AppData data, SyncState st,
      {void Function(WorkSession dropped)? onDropped}) {
    WorkSession? stale;
    final changed = data.resolveOverlaps(
        onDropped: onDropped, onStaleEnded: (s) => stale ??= s);
    if (changed) st.diffLocal(recordsOf(data));
    final was = stale;
    if (was != null) {
      final end =
          data.sessions.where((s) => s.id == was.id).firstOrNull?.end;
      if (end != null) {
        notice = staleEndedNotice(was.start, end);
        _notify();
      }
    }
    return changed;
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
    final crypto = _crypto!;
    final wire = <WireRecord>[];
    final sent = <(String, int)>[];
    final tooLarge = <String>[];
    for (final name in st.pending) {
      if (wire.length >= _maxPerPush) break;
      final plain = utf8.encode(st.payload(name));
      // Der Server lehnt zu große Datensätze ab – und damit den ganzen PUSH.
      // Ein einzelner (z. B. eine sehr lange Notiz) würde so jede weitere
      // Übertragung blockieren; er bleibt ausstehend, bis er kleiner ist.
      if (plain.length + SyncCrypto.overhead > maxRecordBytes) {
        tooLarge.add(name);
        continue;
      }
      final key = await crypto.recordKey(name);
      wire.add(WireRecord(key, await crypto.encrypt(plain, key)));
      sent.add((name, st.records[name]!.modified));
    }
    if (tooLarge.isNotEmpty && notice == null) {
      notice = tooLargeNotice(tooLarge);
      _notify();
    }
    if (wire.isEmpty) return;
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
      if (st == null || st.code != code) return false;
      st.acked(inflight.sent);
      // Alle kleineren Sequenznummern hat der Server vor dem ACK zugestellt.
      st.seq = max(st.seq, firstSeq + inflight.sent.length - 1);
      await _saveState(st);
      return st.pending.isNotEmpty;
    });
    if (more) _schedulePush();
  }

  Future<void> _onVaultDeleted() async {
    if (!enabled) return; // schon behandelt
    final requested = _deleteDone;
    final byUs = requested != null || _deleteRequested;
    _deleteDone = null;
    _deleteRequested = false;
    _generation++;
    _retryTimer?.cancel();
    _closeChannel();
    _dropLeadership();
    await _store.saveSyncState(null);
    _reset();
    if (requested != null) {
      requested.complete();
    } else if (!byUs) {
      notice = 'Die Synchronisation wurde auf einem anderen Gerät beendet '
          'und die Daten auf dem Server gelöscht. Die Daten auf diesem Gerät '
          'bleiben erhalten.';
      _notify();
    }
  }
}
