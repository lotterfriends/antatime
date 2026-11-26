import 'dart:convert';

import 'package:antatime/app_state.dart';
import 'package:antatime/auto_track.dart';
import 'package:antatime/models.dart';
import 'package:antatime/repository.dart';
import 'package:antatime/sync/sync_service.dart';
import 'package:antatime/sync/sync_records.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Rechner wurde mit laufender Zeit heruntergefahren, beendet wurde sie
/// danach auf dem Handy. Beim Hochfahren kommt der Sync erst spät.
void main() {
  late Repository repo;
  late AppState state;
  late SyncService sync;
  final yesterday = DateTime.now().subtract(const Duration(days: 1));

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    repo = Repository();
    await repo.saveSessions([WorkSession(id: 'gestern', start: yesterday)]);
    await repo.saveAutoTrack(AutoTrack.always);
    // Sync eingerichtet, aber noch nicht verbunden.
    await repo.saveSyncState(
        jsonEncode(SyncState(url: 'localhost', code: 'test').toJson()));
    sync = SyncService(repo, networkChanges: () => const Stream.empty())
      ..code = 'test'
      ..status = SyncStatus.connecting;
    state = AppState(repo, await repo.load(), sync: sync);
  });

  tearDown(() => state.dispose());

  /// Wie der Sync: Stand des Handys speichern, dann „online“.
  Future<void> handyBeendetGestern() async {
    await repo.saveSessions([
      WorkSession(
          id: 'gestern',
          start: yesterday,
          end: yesterday.add(const Duration(hours: 1))),
    ]);
    sync.status = SyncStatus.online;
    sync.notifyListeners();
  }

  test('Startet nach spätem Sync doch noch automatisch', () async {
    expect(await state.autoStartTracking(syncWait: Duration.zero), isFalse);

    final waiting =
        state.waitForStaleRunningSync(const Duration(seconds: 5));
    await handyBeendetGestern();
    expect(await waiting, isTrue);

    expect(await state.autoStartTracking(syncWait: Duration.zero), isTrue);
    expect(state.data.running?.id, isNot('gestern'));
    expect(dayOf(state.data.running!.start), dayOf(DateTime.now()));
  });

  test('Kein Nachholen, wenn der Nutzer inzwischen selbst gehandelt hat',
      () async {
    final waiting =
        state.waitForStaleRunningSync(const Duration(seconds: 5));
    await state.toggle(to: false);
    await handyBeendetGestern();
    expect(await waiting, isFalse);
  });

  test('Kein Warten bei laufender Zeit von heute', () async {
    await repo.saveSessions([WorkSession(id: 'heute', start: DateTime.now())]);
    await state.reload();
    expect(await state.waitForStaleRunningSync(const Duration(seconds: 5)),
        isFalse);
  });

  test('Kein Warten, wenn der Sync schon verbunden ist', () async {
    sync.status = SyncStatus.online;
    expect(await state.waitForStaleRunningSync(const Duration(seconds: 5)),
        isFalse);
  });
}
