import 'dart:async';

import 'package:flutter/widgets.dart';

import 'balance.dart';
import 'models.dart';
import 'notification_service.dart';
import 'repository.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this._repo, this.data) {
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    NotificationService.instance.onToggle = toggle;
  }

  final Repository _repo;
  AppData data;
  late final Timer _ticker;
  DateTime now = DateTime.now();
  int _tickCount = 0;

  BalanceCalculator get calc => BalanceCalculator(data, now);

  bool get isRunning => data.running != null;

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
    if (state == AppLifecycleState.resumed) reload();
  }

  Future<void> reload() async {
    data = await _repo.load();
    now = DateTime.now();
    notifyListeners();
  }

  Future<void> _syncNotification() =>
      NotificationService.instance.update(data);

  Future<void> toggle() async {
    // Vor dem Umschalten frisch laden, falls die Benachrichtigung
    // inzwischen den Zustand geändert hat.
    data = await _repo.load();
    final started = Repository.toggle(data, DateTime.now());
    now = DateTime.now();
    await _repo.saveSessions(data.sessions);
    notifyListeners();
    if (started) await NotificationService.instance.requestPermission();
    await _syncNotification();
  }

  Future<void> upsertSession(WorkSession session) async {
    final i = data.sessions.indexWhere((s) => s.id == session.id);
    if (i >= 0) {
      data.sessions[i] = session;
    } else {
      data.sessions.add(session);
    }
    await _repo.saveSessions(data.sessions);
    notifyListeners();
    await _syncNotification();
  }

  Future<void> deleteSession(String id) async {
    data.sessions.removeWhere((s) => s.id == id);
    await _repo.saveSessions(data.sessions);
    notifyListeners();
    await _syncNotification();
  }

  Future<void> upsertAbsence(Absence absence) async {
    final i = data.absences.indexWhere((a) => a.id == absence.id);
    if (i >= 0) {
      data.absences[i] = absence;
    } else {
      data.absences.add(absence);
    }
    data.absences.sort((a, b) => b.from.compareTo(a.from));
    await _repo.saveAbsences(data.absences);
    notifyListeners();
  }

  Future<void> deleteAbsence(String id) async {
    data.absences.removeWhere((a) => a.id == id);
    await _repo.saveAbsences(data.absences);
    notifyListeners();
  }

  Future<void> updateSettings(void Function(Settings s) change) async {
    change(data.settings);
    await _repo.saveSettings(data.settings);
    notifyListeners();
    if (data.settings.showNotification) {
      await NotificationService.instance.requestPermission();
    }
    await _syncNotification();
  }

  @override
  void dispose() {
    _ticker.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
