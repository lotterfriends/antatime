// Ende-zu-Ende-Test gegen einen laufenden AnTaTime-Server, z. B.:
//
//   (cd ../antatime-server && STORE=memory PORT=18080 npm run dev) &
//   SYNC_TEST_URL=http://127.0.0.1:18080 flutter test test/sync_integration_test.dart
//
// Ohne SYNC_TEST_URL wird der Test übersprungen.
import 'dart:async';
import 'dart:io';

import 'package:antatime/models.dart';
import 'package:antatime/repository.dart';
import 'package:antatime/sync/sync_crypto.dart';
import 'package:antatime/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Speicher eines Geräts. Im Browser teilen sich alle Tabs diesen Speicher
/// (localStorage) und die Sperre (Web Locks).
class FakeStorage implements SyncStore {
  String _data = Repository.exportJson(AppData(
      sessions: [], absences: [], settings: Settings(startDate: DateTime(2026))));
  String? _state;
  Future<void> _lock = Future.value();

  @override
  Future<T> exclusive<T>(Future<T> Function() action) {
    final r = _lock.then((_) => action());
    _lock = r.then((_) {}, onError: (_) {});
    return r;
  }

  @override
  Future<AppData> load() async => Repository.importJson(_data);

  @override
  Future<void> saveAll(AppData data) async =>
      _data = Repository.exportJson(data);

  @override
  Future<String?> loadSyncState() async => _state;

  @override
  Future<void> saveSyncState(String? json) async => _state = json;
}

/// Eine offene App (ein Gerät oder ein Browser-Tab).
class FakeDevice {
  FakeDevice(this.name, [FakeStorage? sharedWith, this.tabLock])
      : storage = sharedWith ?? FakeStorage() {
    sync.onRemoteData = (d) => shown = d;
  }

  final String name;
  final FakeStorage storage;

  /// Im Browser: gemeinsame Sperre, wer die Verbindung hält (Web Locks).
  final FakeTabLock? tabLock;
  late final sync = SyncService(storage,
      networkChanges: () => const Stream.empty(), leaderLock: tabLock?.call);

  /// Was die Oberfläche dieser App gerade anzeigt.
  AppData? shown;

  AppData get data => Repository.importJson(storage._data);

  /// Lokale Änderung wie in der App: speichern, dann melden.
  Future<void> edit(void Function(AppData d) change) async {
    await storage.exclusive(() async {
      final d = await storage.load();
      change(d);
      await storage.saveAll(d);
    });
    sync.localChanged();
  }
}

/// Wie `navigator.locks.request`: Wer zuerst fragt, bekommt die Sperre, die
/// anderen warten der Reihe nach.
class FakeTabLock {
  Future<void> _queue = Future.value();

  Future<void Function()> call(String name) {
    final prev = _queue;
    final released = Completer<void>();
    _queue = prev.then((_) => released.future);
    return prev.then((_) => () {
          if (!released.isCompleted) released.complete();
        });
  }
}

Future<void> waitFor(bool Function() cond, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 5)) {
      fail('Zeitüberschreitung: ${reason ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final url = Platform.environment['SYNC_TEST_URL'];

  test('Zwei Geräte gleichen sich sofort ab', () async {
    final a = FakeDevice('A');
    final b = FakeDevice('B');
    final code = SyncCrypto.generateCode();

    await a.edit((d) => d.settings.weeklyHours = 32);
    await a.edit((d) => d.sessions.add(WorkSession(
        id: 's1', start: DateTime(2026, 11, 5, 8), end: DateTime(2026, 11, 5, 12))));

    await a.sync.enable(url: url!, code: code, join: false);
    await waitFor(() => a.sync.status == SyncStatus.online, reason: 'A online');

    // B hat eigene Daten und tritt bei: Einstellungen kommen von A,
    // die eigene Arbeitszeit bleibt erhalten und geht an A.
    await b.edit((d) => d.sessions.add(WorkSession(
        id: 's2', start: DateTime(2026, 11, 6, 9), end: DateTime(2026, 11, 6, 10))));
    await b.sync.enable(url: url, code: code, join: true);
    await waitFor(() => b.data.sessions.length == 2, reason: 'B hat beide');
    expect(b.data.settings.weeklyHours, 32);
    await waitFor(() => a.data.sessions.length == 2, reason: 'A hat s2');

    // Live: Änderung auf A ist sofort auf B.
    final sw = Stopwatch()..start();
    await a.edit((d) => d.sessions.add(WorkSession(id: 'run', start: DateTime.now())));
    await waitFor(() => b.data.running?.id == 'run', reason: 'B sieht laufende Zeit');
    // ignore: avoid_print
    print('Live-Übertragung A → B: ${sw.elapsedMilliseconds} ms');

    // Und zurück: B beendet, A sieht das Ende; B löscht s1.
    await b.edit((d) => d.running!.end = DateTime.now());
    await b.edit((d) => d.sessions.removeWhere((s) => s.id == 's1'));
    await waitFor(() => a.data.running == null && a.data.sessions.length == 2,
        reason: 'A übernimmt Ende und Löschung');

    // Drittes Gerät (Code von Hand abgetippt) bekommt den gleichen Stand.
    final c = FakeDevice('C');
    final typed = SyncCrypto.formatCode(code).toLowerCase();
    await c.sync.enable(
        url: url, code: SyncCrypto.normalizeCode(typed)!, join: true);
    await waitFor(() => c.data.sessions.length == 2, reason: 'C vollständig');
    expect(Repository.exportJson(c.data, now: DateTime(2026)),
        Repository.exportJson(a.data, now: DateTime(2026)));

    // Löschen auf dem Server beendet den Sync überall.
    expect(await a.sync.disable(deleteRemote: true), isTrue);
    await waitFor(() => !b.sync.enabled && !c.sync.enabled,
        reason: 'B und C beenden');
    expect(b.sync.notice, isNotNull);
    expect(b.data.sessions, hasLength(2), reason: 'lokale Daten bleiben');

    // Der gelöschte Code ist verbrannt.
    final d = FakeDevice('D');
    await d.sync.enable(url: url, code: code, join: true);
    await waitFor(() => !d.sync.enabled, reason: 'D wird abgewiesen');

    for (final x in [a, b, c, d]) {
      x.sync.dispose();
    }
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);

  test('Viele gleichzeitig offene Geräte bleiben synchron', () async {
    final code = SyncCrypto.generateCode();
    // Mehr als das frühere Limit von 20 Verbindungen pro Code.
    final devices = [for (var i = 0; i < 30; i++) FakeDevice('G$i')];
    await devices.first.sync.enable(url: url!, code: code, join: false);
    for (final d in devices.skip(1)) {
      await d.sync.enable(url: url, code: code, join: true);
    }
    await waitFor(() => devices.every((d) => d.sync.status == SyncStatus.online),
        reason: 'alle online');

    // Jedes Gerät ändert etwas; alle sehen alle Änderungen.
    for (final (i, d) in devices.indexed) {
      await d.edit((x) => x.sessions.add(WorkSession(
          id: 'g$i', start: DateTime(2026, 11, 1, 8).add(Duration(hours: i)))));
    }
    await waitFor(
        () => devices.every((d) => d.data.sessions.length == devices.length),
        reason: 'alle haben alle Arbeitszeiten');
    for (final d in devices) {
      d.sync.dispose();
    }
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);

  test('Mehrere Tabs im selben Browser', () async {
    final code = SyncCrypto.generateCode();
    final phone = FakeDevice('Handy');
    final tab1 = FakeDevice('Tab 1');
    final tab2 = FakeDevice('Tab 2', tab1.storage);

    await phone.sync.enable(url: url!, code: code, join: false);
    await tab1.sync.enable(url: url, code: code, join: true);
    // Tab 2 übernimmt die Einrichtung aus Tab 1 (gemeinsamer Speicher).
    tab2.sync.localChanged();
    await waitFor(() => tab2.sync.enabled && tab2.sync.status == SyncStatus.online,
        reason: 'Tab 2 folgt Tab 1');

    // Änderung in Tab 1: Handy bekommt sie, und auch die Anzeige von Tab 2
    // wird sofort aktualisiert, obwohl der Speicher sie schon enthält.
    await tab1.edit((d) => d.sessions.add(WorkSession(id: 't1', start: DateTime.now())));
    await waitFor(() => phone.data.running?.id == 't1', reason: 'Handy');
    await waitFor(() => tab2.shown?.running?.id == 't1', reason: 'Tab 2 zeigt an');

    // Änderung am Handy erreicht beide Tabs.
    await phone.edit((d) => d.running!.end = DateTime.now());
    await waitFor(
        () => tab1.data.running == null &&
            tab1.shown?.running == null &&
            tab2.shown?.running == null,
        reason: 'beide Tabs');

    // Beenden in Tab 1 beendet auch Tab 2.
    await tab1.sync.disable();
    tab2.sync.localChanged();
    await waitFor(() => !tab2.sync.enabled, reason: 'Tab 2 beendet');
    expect(phone.sync.enabled, isTrue);

    for (final d in [phone, tab1, tab2]) {
      d.sync.dispose();
    }
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);

  test('Mehrere Tabs teilen sich eine Verbindung', () async {
    final code = SyncCrypto.generateCode();
    final lock = FakeTabLock();
    final phone = FakeDevice('Handy');
    final tab1 = FakeDevice('Tab 1', null, lock);
    final tab2 = FakeDevice('Tab 2', tab1.storage, lock);

    await phone.sync.enable(url: url!, code: code, join: false);
    await tab1.sync.enable(url: url, code: code, join: true);
    await waitFor(() => tab1.sync.status == SyncStatus.online, reason: 'Tab 1');
    tab2.sync.localChanged();
    await waitFor(() => tab2.sync.status == SyncStatus.otherTab,
        reason: 'Tab 2 wartet');

    // Änderung in Tab 2 sendet Tab 1 (ausgelöst durch das storage-Event).
    await tab2.edit((d) => d.sessions.add(WorkSession(id: 't2', start: DateTime.now())));
    tab1.sync.localChanged();
    await waitFor(() => phone.data.running?.id == 't2', reason: 'Handy');

    // Änderung am Handy landet über Tab 1 im gemeinsamen Speicher.
    await phone.edit((d) => d.running!.end = DateTime.now());
    await waitFor(() => tab2.data.running == null, reason: 'gemeinsamer Speicher');

    // Tab 1 wird geschlossen: Tab 2 übernimmt die Verbindung.
    tab1.sync.dispose();
    await waitFor(() => tab2.sync.status == SyncStatus.online, reason: 'Tab 2 übernimmt');
    await phone.edit((d) => d.sessions.add(WorkSession(id: 'p', start: DateTime.now())));
    await waitFor(() => tab2.data.running?.id == 'p', reason: 'Tab 2 empfängt');

    for (final d in [phone, tab2]) {
      d.sync.dispose();
    }
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);
}
