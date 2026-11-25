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
import 'package:intl/date_symbol_data_local.dart';

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
  setUpAll(() => initializeDateFormatting('de_DE'));
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
    // Der Server meldet seine Uhrzeit: gleiche Maschine, keine Abweichung.
    expect(a.sync.clockOffset!.abs(), lessThan(const Duration(seconds: 2)));
    expect(a.sync.clockWarning, isNull);

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

  test('Auf zwei Geräten gestartet: die zuerst gestartete Zeit gewinnt',
      () async {
    final code = SyncCrypto.generateCode();
    final phone = FakeDevice('Handy');
    final pc = FakeDevice('PC');
    await phone.sync.enable(url: url!, code: code, join: false);
    await pc.sync.enable(url: url, code: code, join: true);
    await waitFor(
        () => phone.sync.status == SyncStatus.online &&
            pc.sync.status == SyncStatus.online,
        reason: 'beide online');

    // PC offline: Er kennt die laufende Zeit vom Handy noch nicht und
    // startet selbst (z. B. Autostart beim Hochfahren).
    pc.sync.dispose();
    final pcAgain = FakeDevice('PC', pc.storage);
    await phone.edit((d) => d.sessions.add(WorkSession(
        id: 'handy', start: DateTime.now().subtract(const Duration(hours: 1)))));
    await pcAgain.edit((d) => d.sessions.add(
        WorkSession(id: 'pc', start: DateTime.now())));

    // PC kommt online (mit der Änderung): Beide sehen nur noch die frühere
    // Zeit.
    bool onlyPhone(AppData d) =>
        d.sessions.length == 1 && d.running?.id == 'handy';
    await waitFor(() => onlyPhone(pcAgain.data), reason: 'PC behält Handy-Zeit');
    await waitFor(() => onlyPhone(phone.data), reason: 'Handy löscht PC-Zeit');
    expect(pcAgain.shown?.running?.id, 'handy');

    phone.sync.dispose();
    pcAgain.sync.dispose();
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);

  test('Doppelter Start: Pause und Feierabend des anderen Geräts bleiben',
      () async {
    final code = SyncCrypto.generateCode();
    final phone = FakeDevice('Handy');
    final pc = FakeDevice('PC');
    final day = DateTime.now().subtract(const Duration(hours: 6));
    DateTime t(int minutes) => day.add(Duration(minutes: minutes));

    // Handy: gestartet, Pause, weiter, Feierabend – PC weiß nichts davon
    // und hat eine Stunde nach dem Handy selbst gestartet.
    await phone.edit((d) => d.sessions.addAll([
          WorkSession(id: 'h1', start: t(0), end: t(120)),
          WorkSession(id: 'h2', start: t(150), end: t(240)),
        ]));
    await pc.edit((d) => d.sessions.add(WorkSession(id: 'pc', start: t(60))));

    await phone.sync.enable(url: url!, code: code, join: false);
    await waitFor(() => phone.sync.status == SyncStatus.online,
        reason: 'Handy online');
    await pc.sync.enable(url: url, code: code, join: true);

    bool phoneWins(AppData d) =>
        d.sessions.map((s) => s.id).join(',') == 'h1,h2' && d.running == null;
    await waitFor(() => phoneWins(pc.data), reason: 'PC übernimmt Handy-Stand');
    await waitFor(() => phoneWins(phone.data), reason: 'Handy bleibt');

    phone.sync.dispose();
    pc.sync.dispose();
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);

  test('Nachholen in mehreren Teilen löscht keine laufende Zeit', () async {
    final code = SyncCrypto.generateCode();
    final phone = FakeDevice('Handy');
    final pc = FakeDevice('PC');
    final day = DateTime.now().subtract(const Duration(hours: 3));
    await phone.sync.enable(url: url!, code: code, join: false);
    await pc.sync.enable(url: url, code: code, join: true);
    await waitFor(
        () => phone.sync.status == SyncStatus.online &&
            pc.sync.status == SyncStatus.online,
        reason: 'beide online');

    // Beide kennen die laufende Zeit x; dann ist der PC offline.
    await phone.edit((d) => d.sessions.add(WorkSession(id: 'x', start: day)));
    await waitFor(() => pc.data.running?.id == 'x', reason: 'PC kennt x');
    pc.sync.dispose();

    // Handy: Pause, weiter (y), danach viele andere Änderungen und zuletzt
    // eine Notiz an x – x kommt beim Nachholen damit erst nach y.
    await phone.edit((d) {
      d.running!.end = day.add(const Duration(hours: 1));
      d.sessions.add(WorkSession(id: 'y', start: day.add(const Duration(hours: 2))));
    });
    // y erst auf dem Server, dann der Rest – sonst landet alles in einem Teil.
    final observer = FakeDevice('Beobachter');
    await observer.sync.enable(url: url, code: code, join: true);
    await waitFor(() => observer.data.running?.id == 'y', reason: 'y gesendet');
    await phone.edit((d) {
      for (var i = 0; i < 600; i++) {
        final s = DateTime(2025, 1, 1).add(Duration(hours: 2 * i));
        d.sessions.add(WorkSession(
            id: 'old$i', start: s, end: s.add(const Duration(hours: 1))));
      }
    });
    await waitFor(() => observer.data.sessions.length == 602,
        reason: 'alte Zeiten gesendet');
    await phone.edit((d) =>
        d.sessions.firstWhere((s) => s.id == 'x').note = 'später ergänzt');
    await waitFor(
        () =>
            observer.data.sessions.length == 602 &&
            observer.data.sessions.any((s) => s.note == 'später ergänzt'),
        reason: 'alles gesendet');
    observer.sync.dispose();

    // PC holt nach: y bleibt überall erhalten.
    final pcAgain = FakeDevice('PC', pc.storage);
    pcAgain.sync.localChanged();
    await waitFor(() => pcAgain.data.sessions.length == 602,
        reason: 'PC vollständig');
    await waitFor(() => pcAgain.sync.status == SyncStatus.online,
        reason: 'PC online');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (final d in [pcAgain, phone]) {
      expect(d.data.running?.id, 'y', reason: d.name);
      expect(d.data.sessions.length, 602, reason: d.name);
    }

    phone.sync.dispose();
    pcAgain.sync.dispose();
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);

  test('Beitreten mit laufender Zeit: Hinweis, wenn sie verworfen wird',
      () async {
    final code = SyncCrypto.generateCode();
    final phone = FakeDevice('Handy');
    final pc = FakeDevice('PC');
    final start = DateTime.now().subtract(const Duration(hours: 3));
    await phone.edit((d) => d.sessions.add(WorkSession(
        id: 'h', start: start, end: start.add(const Duration(hours: 1)))));
    await pc.edit((d) => d.sessions.add(WorkSession(
        id: 'pc', start: start.add(const Duration(minutes: 30)))));
    // Unbeteiligt: das Handy bekommt keinen Hinweis.
    await phone.sync.enable(url: url!, code: code, join: false);
    await waitFor(() => phone.sync.status == SyncStatus.online,
        reason: 'Handy online');

    await pc.sync.enable(url: url, code: code, join: true);
    await waitFor(() => pc.sync.notice != null, reason: 'Hinweis am PC');
    expect(pc.sync.notice, contains('Zeiterfassung seit'));
    expect(pc.data.running, isNull);
    await waitFor(() => phone.data.sessions.length == 1, reason: 'Handy');
    expect(phone.sync.notice, isNull);

    phone.sync.dispose();
    pc.sync.dispose();
  }, skip: url == null ? 'SYNC_TEST_URL nicht gesetzt' : null);

  test('Alter Tab mit laufender Zeit überschreibt keine späteren Tage',
      () async {
    final code = SyncCrypto.generateCode();
    final phone = FakeDevice('Handy');
    final tab = FakeDevice('Tab');
    final today = dayOf(DateTime.now());
    DateTime t(int daysAgo, int h) =>
        today.subtract(Duration(days: daysAgo)).add(Duration(hours: h));

    await phone.sync.enable(url: url!, code: code, join: false);
    await tab.sync.enable(url: url, code: code, join: true);
    await waitFor(() => tab.sync.status == SyncStatus.online, reason: 'Tab');

    // Vor drei Tagen im Tab gestartet, das Handy sieht es.
    await tab.edit((d) => d.sessions.add(WorkSession(id: 'r', start: t(3, 8))));
    await waitFor(() => phone.data.running?.id == 'r', reason: 'Handy sieht r');
    await waitFor(() => tab.sync.status == SyncStatus.online);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // Der Tab verliert die Verbindung (Rechner im Ruhezustand).
    tab.sync.dispose();

    // Am Handy: Feierabend und zwei weitere Tage.
    await phone.edit((d) => d.running!.end = t(3, 17));
    await phone.edit((d) => d.sessions.addAll([
          WorkSession(id: 'd2', start: t(2, 8), end: t(2, 16)),
          WorkSession(id: 'd1', start: t(1, 8), end: t(1, 16)),
        ]));
    final expected = [(t(3, 8), t(3, 17)), (t(2, 8), t(2, 16)), (t(1, 8), t(1, 16))];
    List<(DateTime, DateTime?)> times(FakeDevice d) =>
        d.data.sessions.map((s) => (s.start, s.end)).toList();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Tage später: Der Tab wacht auf, zeigt „läuft seit drei Tagen“, und es
    // wird sofort „Pause“ gedrückt – noch bevor der Abgleich da ist.
    final tabAgain = FakeDevice('Tab', tab.storage);
    await tabAgain.edit((d) => d.running!.end = DateTime.now());
    await waitFor(() => tabAgain.sync.status == SyncStatus.online,
        reason: 'Tab wieder online');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (final d in [tabAgain, phone]) {
      expect(times(d), expected, reason: d.name);
    }
    tabAgain.sync.dispose();

    // Dasselbe mit einer Zeit, die der Server nie gesehen hat: Sie endet
    // mit dem Beginn der nächsten Arbeitszeit, und der Tab weist darauf hin.
    final offline = FakeDevice('Tab 2', tab.storage);
    await offline.edit(
        (d) => d.sessions.add(WorkSession(id: 'u', start: t(2, 7))));
    await waitFor(() => offline.sync.notice != null, reason: 'Hinweis');
    expect(offline.sync.notice, contains('Bitte ihr Ende prüfen'));
    await waitFor(() => phone.data.sessions.length == 4, reason: 'Handy hat u');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (final d in [offline, phone]) {
      expect(times(d), [
        expected[0],
        (t(2, 7), t(2, 8)),
        ...expected.skip(1),
      ], reason: d.name);
    }
    expect(phone.sync.notice, isNull);

    offline.sync.dispose();
    phone.sync.dispose();
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
      final start = DateTime(2026, 11, 1, 8).add(Duration(hours: i));
      await d.edit((x) => x.sessions.add(WorkSession(
          id: 'g$i', start: start, end: start.add(const Duration(minutes: 30)))));
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
