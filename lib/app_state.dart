import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'auto_track.dart';
import 'balance.dart';
import 'models.dart';
import 'notification_service.dart';
import 'repository.dart';
import 'sync/sync_service.dart';
import 'sync/tab_coordination.dart';
import 'tray_icon_style.dart';

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
    // Im Browser: Änderungen anderer Tabs sofort übernehmen (und, falls
    // dieser Tab die Sync-Verbindung hält, gleich weitergeben).
    _tabChanges = otherTabChanges().listen((_) {
      _tabReload?.cancel();
      _tabReload = Timer(const Duration(milliseconds: 200), reload);
    });
  }

  StreamSubscription<void>? _tabChanges;
  Timer? _tabReload;

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
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      sync.pause();
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

  /// Speichert eine neue oder bearbeitete Arbeitszeit, falls sie zu den
  /// aktuellen Daten passt (siehe [validateSession]) – geprüft unter der
  /// Sperre, nachdem frisch geladen wurde. Gibt sonst die Fehlermeldung
  /// zurück.
  Future<String?> upsertSession(
    WorkSession session, {
    WorkSession? original,
  }) async {
    final error = await _repo.exclusive(() async {
      data = await _repo.load();
      now = DateTime.now();
      final error = validateSession(data, session, now, original: original);
      if (error != null) return error;
      final i = data.sessions.indexWhere((s) => s.id == session.id);
      if (i >= 0) {
        data.sessions[i] = session;
      } else {
        data.sessions.add(session);
      }
      data.sessions.sort((a, b) => a.start.compareTo(b.start));
      await _repo.saveSessions(data.sessions);
      return null;
    });
    _changed();
    if (error == null) await _syncNotification();
    return error;
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

  /// Ändert die Einstellungen. Ändert sich dabei eine Einstellung, die das
  /// Stundenkonto bestimmt ([Settings.periodFields]), gilt sie erst ab heute:
  /// Die bisherigen Werte bleiben für die Tage bis gestern gespeichert (siehe
  /// [Settings.periods]). Gibt dann `true` zurück – mit
  /// [applySettingsRetroactively] lässt sich das aufheben.
  Future<bool> updateSettings(void Function(Settings s) change) async {
    final kept = await _repo.exclusive(() async {
      data = await _repo.load();
      final s = data.settings;
      final before = s.periodValues();
      change(s);
      final today = dayOf(DateTime.now());
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      var kept = false;
      if (!_sameValues(before, s.periodValues()) &&
          s.startDate.isBefore(today)) {
        // Heute schon geändert: Der Zeitraum bis gestern steht bereits.
        kept = true;
        if (s.periods.isEmpty || s.periods.last.until.isBefore(yesterday)) {
          s.periods = [...s.periods, SettingsPeriod(yesterday, before)];
        }
      }
      await _repo.saveSettings(s);
      return kept;
    });
    _changed();
    if (data.settings.showNotification ||
        data.settings.reminderMinutes != null ||
        data.settings.targetReminder) {
      await NotificationService.instance.requestPermission();
    }
    await _syncNotification();
    return kept;
  }

  static bool _sameValues(Map<String, dynamic> a, Map<String, dynamic> b) =>
      jsonEncode(a) == jsonEncode(b);

  /// Die heute geänderten Berechnungs-Einstellungen sollen doch auch für die
  /// Vergangenheit gelten: den Zeitraum bis gestern wieder entfernen.
  Future<void> applySettingsRetroactively() async {
    await _repo.exclusive(() async {
      data = await _repo.load();
      final s = data.settings;
      final today = dayOf(DateTime.now());
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      if (s.periods.isNotEmpty && s.periods.last.until == yesterday) {
        s.periods = s.periods.sublist(0, s.periods.length - 1);
        await _repo.saveSettings(s);
      }
    });
    _changed();
  }

  /// Darstellung des Tray-Symbols (nur dieses Gerät); beim Start mit
  /// [loadDeviceSettings] geladen.
  TrayIconStyle trayIconStyle = TrayIconStyle.color;

  Future<void> loadDeviceSettings() async {
    trayIconStyle = await _repo.loadTrayIconStyle();
  }

  Future<void> setTrayIconStyle(TrayIconStyle style) async {
    trayIconStyle = style;
    await _repo.saveTrayIconStyle(style);
    notifyListeners();
  }

  /// Zeiterfassung beim Programmstart beginnen (nur dieses Gerät).
  Future<AutoTrack> autoTrack() => _repo.loadAutoTrack();

  Future<void> setAutoTrack(AutoTrack mode) async {
    await _repo.saveAutoTrack(mode);
    notifyListeners();
  }

  /// Spätester automatischer Start an Arbeitstagen (Minuten nach
  /// Mitternacht, `null` = ohne Begrenzung; nur dieses Gerät).
  Future<int?> autoTrackUntil() => _repo.loadAutoTrackUntil();

  Future<void> setAutoTrackUntil(int? minutes) async {
    await _repo.saveAutoTrackUntil(minutes);
    notifyListeners();
  }

  /// Beim Programmstart: Zeiterfassung beginnen, falls so eingestellt
  /// (siehe [shouldAutoTrack]). Gibt `true` zurück, wenn sie gestartet wurde.
  ///
  /// Wartet vorher bis zu [syncWait] auf den Sync: Läuft die Zeiterfassung
  /// schon auf einem anderen Gerät, wird sie nicht ein zweites Mal gestartet.
  /// (Ohne Netz startet sie danach trotzdem; der Sync löst das später auf.)
  Future<bool> autoStartTracking({
    Duration syncWait = const Duration(seconds: 10),
  }) async {
    final mode = await _repo.loadAutoTrack();
    if (mode == AutoTrack.off) return false;
    await sync.waitUntilSynced(syncWait);
    final until = await _repo.loadAutoTrackUntil();
    final started = await _repo.exclusive(() async {
      data = await _repo.load();
      now = DateTime.now();
      stoppedToday = await _repo.stoppedOn(now);
      if (!shouldAutoTrack(
        mode,
        data,
        now,
        stoppedToday: stoppedToday,
        untilMinutes: until,
      )) {
        return false;
      }
      Repository.toggle(data, now);
      await _repo.saveSessions(data.sessions);
      await _repo.clearStopped();
      stoppedToday = false;
      return true;
    });
    _changed();
    if (started) await _syncNotification();
    return started;
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
    _tabChanges?.cancel();
    _tabReload?.cancel();
    sync.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
