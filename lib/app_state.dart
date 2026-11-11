import 'dart:async';

import 'package:flutter/widgets.dart';

import 'balance.dart';
import 'models.dart';
import 'notification_service.dart';
import 'repository.dart';
import 'sync/sync_service.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this._repo, this.data, {SyncService? sync})
      : sync = sync ?? SyncService(_repo) {
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    NotificationService.instance.onToggle = toggle;
    NotificationService.instance.onStart = () {
      if (!isRunning) toggle();
    };
    NotificationService.instance.onFinish = finishDay;
    NotificationService.instance.onDataChanged = reload;
    this.sync.onRemoteData = _onRemoteData;
  }

  final Repository _repo;
  AppData data;

  /// Optionale Synchronisation mit anderen Geräten.
  final SyncService sync;
  late final Timer _ticker;
  DateTime now = DateTime.now();
  int _tickCount = 0;

  BalanceCalculator get calc => BalanceCalculator(data, now);

  bool get isRunning => data.running != null;

  /// Heute wurde „Feierabend“ gewählt (Benachrichtigung/Infobereich).
  bool stoppedToday = false;

  void _tick() {
    now = DateTime.now();
    // Regelmäßig neu laden, damit Aktionen aus der Benachrichtigung
    // (Hintergrund-Isolate) auch bei geöffneter App ankommen.
    if (++_tickCount % 5 == 0) {
      reload();
    } else {
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Danach die Erinnerungen neu planen (neuer Tag, Zeitraum verlängern).
      reload().then((_) => _syncNotification());
      sync.resume();
    }
  }

  /// Änderungen anderer Geräte sind bereits gespeichert.
  void _onRemoteData(AppData remote) {
    data = remote;
    now = DateTime.now();
    notifyListeners();
    _syncNotification();
  }

  /// Nach jeder lokalen Änderung: Oberfläche aktualisieren und an andere
  /// Geräte weitergeben.
  ///
  /// Alle Änderungen laden die Daten vorher frisch: Andere Tabs, die
  /// Benachrichtigung oder der Sync können sie inzwischen geändert haben.
  /// Sonst würde ein veralteter Stand im Speicher deren Änderungen
  /// überschreiben (und die Löschung an alle Geräte verteilen).
  void _changed() {
    notifyListeners();
    sync.localChanged();
  }

  Future<void> reload() async {
    data = await _repo.exclusive(_repo.load);
    now = DateTime.now();
    stoppedToday = await _repo.stoppedOn(now);
    _changed();
  }

  Future<void> _syncNotification() =>
      NotificationService.instance.update(data);

  Future<void> toggle() async {
    final started = await _repo.exclusive(() async {
      // Vor dem Umschalten frisch laden, falls die Benachrichtigung
      // inzwischen den Zustand geändert hat.
      data = await _repo.load();
      final started = Repository.toggle(data, DateTime.now());
      now = DateTime.now();
      await _repo.saveSessions(data.sessions);
      if (started) {
        await _repo.clearStopped();
        stoppedToday = false;
      }
      return started;
    });
    _changed();
    if (started) await NotificationService.instance.requestPermission();
    await _syncNotification();
  }

  /// „Feierabend“: laufende Arbeitszeit beenden und für heute als erledigt
  /// markieren (wie die Feierabend-Aktion der Android-Benachrichtigung).
  Future<void> finishDay() async {
    await _repo.exclusive(() async {
      data = await _repo.load();
      now = DateTime.now();
      if (data.running != null) {
        Repository.toggle(data, now);
        await _repo.saveSessions(data.sessions);
      }
      await _repo.markStopped(now);
      stoppedToday = true;
    });
    _changed();
    await _syncNotification();
  }

  Future<void> upsertSession(WorkSession session) async {
    await _repo.exclusive(() async {
      data = await _repo.load();
      final i = data.sessions.indexWhere((s) => s.id == session.id);
      if (i >= 0) {
        data.sessions[i] = session;
      } else {
        data.sessions.add(session);
      }
      await _repo.saveSessions(data.sessions);
    });
    _changed();
    await _syncNotification();
  }

  Future<void> deleteSession(String id) async {
    await _repo.exclusive(() async {
      data = await _repo.load();
      data.sessions.removeWhere((s) => s.id == id);
      await _repo.saveSessions(data.sessions);
    });
    _changed();
    await _syncNotification();
  }

  /// Pause zwischen zwei Arbeitszeiten löschen und beide zusammenfassen.
  Future<void> deletePause(String beforeId, String afterId) async {
    final ok = await _repo.exclusive(() async {
      // Frisch laden, falls die Benachrichtigung den Zustand geändert hat.
      data = await _repo.load();
      if (!Repository.mergeSessions(data, beforeId, afterId)) return false;
      await _repo.saveSessions(data.sessions);
      return true;
    });
    if (!ok) return;
    _changed();
    await _syncNotification();
  }

  Future<void> upsertAbsence(Absence absence) async {
    await _repo.exclusive(() async {
      data = await _repo.load();
      final i = data.absences.indexWhere((a) => a.id == absence.id);
      if (i >= 0) {
        data.absences[i] = absence;
      } else {
        data.absences.add(absence);
      }
      data.absences.sort((a, b) => b.from.compareTo(a.from));
      await _repo.saveAbsences(data.absences);
    });
    _changed();
  }

  Future<void> deleteAbsence(String id) async {
    await _repo.exclusive(() async {
      data = await _repo.load();
      data.absences.removeWhere((a) => a.id == id);
      await _repo.saveAbsences(data.absences);
    });
    _changed();
  }

  Future<void> updateSettings(void Function(Settings s) change) async {
    await _repo.exclusive(() async {
      data = await _repo.load();
      change(data.settings);
      await _repo.saveSettings(data.settings);
    });
    _changed();
    if (data.settings.showNotification ||
        data.settings.reminderMinutes != null ||
        data.settings.targetReminder) {
      await NotificationService.instance.requestPermission();
    }
    await _syncNotification();
  }

  /// Alle Daten und Einstellungen als JSON-Text.
  String exportJson() => Repository.exportJson(data);

  /// Ersetzt alle Daten und Einstellungen durch [imported].
  Future<void> importData(AppData imported) async {
    await _repo.exclusive(() async {
      await _repo.saveAll(imported);
      if (imported.running != null) await _repo.clearStopped();
      data = imported;
    });
    now = DateTime.now();
    _changed();
    await _syncNotification();
  }

  @override
  void dispose() {
    _ticker.cancel();
    sync.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
