import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';

/// Desktop: Nach dem Autostart per Benachrichtigung fragen, ob die
/// Zeiterfassung beginnen soll – mit „Jetzt starten“-Knopf.
///
/// Ein Klick auf die Benachrichtigung selbst öffnet das Fenster. Wird die
/// Arbeitszeit anderweitig gestartet (Fenster, Infobereich, Sync), wird die
/// Benachrichtigung entfernt.
class StartPrompt {
  StartPrompt._();
  static final instance = StartPrompt._();

  static const _id = 2;
  static const _actionStart = 'start';
  static const _payloadOpen = 'open';
  static const _category = 'startPrompt';

  final _plugin = FlutterLocalNotificationsPlugin();
  AppState? _state;
  bool _initialized = false;
  bool _shown = false;

  static bool get supported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  Future<void> _init() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: InitializationSettings(
        linux: LinuxInitializationSettings(
          defaultActionName: 'AnTaTime öffnen',
          defaultIcon: _linuxIcon(),
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [
            DarwinNotificationCategory(_category, actions: [
              DarwinNotificationAction.plain(_actionStart, 'Jetzt starten'),
            ]),
          ],
        ),
        windows: const WindowsInitializationSettings(
          appName: 'AnTaTime',
          appUserModelId: 'lotterfriends.AnTaTime',
          guid: '5f3c2a8e-9d41-4b6e-a7c3-1e2f8b9d0c64',
        ),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
    _initialized = true;
  }

  /// Fenster-Symbol (Tarball/AppImage: neben der Programmdatei, .deb: Theme).
  static LinuxNotificationIcon? _linuxIcon() {
    if (!Platform.isLinux) return null;
    final bundled = File(
        '${File(Platform.resolvedExecutable).parent.path}/data/antatime.png');
    return bundled.existsSync()
        ? FilePathLinuxIcon(bundled.path)
        : ThemeLinuxIcon('com.lotterfriends.antatime');
  }

  /// macOS fragt einmalig nach der Erlaubnis für Benachrichtigungen; am
  /// besten beim Einschalten des Autostarts aufrufen.
  Future<void> requestPermission() async {
    if (!supported) return;
    try {
      await _init();
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: false, sound: true);
    } on Exception catch (e) {
      debugPrint('Startfrage: $e');
    }
  }

  /// Zeigt die Frage, sofern die Arbeitszeit nicht schon läuft.
  Future<void> show(AppState state) async {
    if (!supported || state.isRunning) return;
    _state = state;
    try {
      await _init();
      await requestPermission();
      await _plugin.show(
        id: _id,
        title: 'Zeiterfassung starten?',
        body: 'AnTaTime wurde mit dem System gestartet. '
            'Soll die Arbeitszeit jetzt laufen?',
        payload: _payloadOpen,
        notificationDetails: const NotificationDetails(
          linux: LinuxNotificationDetails(
            actions: [
              LinuxNotificationAction(key: _actionStart, label: 'Jetzt starten'),
            ],
            // Bleibt stehen, bis darauf reagiert wird.
            resident: true,
            timeout: LinuxNotificationTimeout.expiresNever(),
            category: LinuxNotificationCategory.presence,
          ),
          macOS: DarwinNotificationDetails(categoryIdentifier: _category),
          windows: WindowsNotificationDetails(
            actions: [
              WindowsAction(content: 'Jetzt starten', arguments: _actionStart),
            ],
            duration: WindowsNotificationDuration.long,
          ),
        ),
      );
      _shown = true;
      state.addListener(_onStateChanged);
    } on Exception catch (e) {
      debugPrint('Startfrage: $e');
    }
  }

  void _onStateChanged() {
    if (_state?.isRunning == true) _dismiss();
  }

  Future<void> _dismiss() async {
    if (!_shown) return;
    _shown = false;
    _state?.removeListener(_onStateChanged);
    try {
      await _plugin.cancel(id: _id);
    } on Exception catch (e) {
      debugPrint('Startfrage: $e');
    }
  }

  Future<void> _onResponse(NotificationResponse r) async {
    final state = _state;
    if (state == null) return;
    // Windows meldet die Argumente des Knopfs als actionId, beim Klick auf
    // die Benachrichtigung die payload.
    if (r.actionId == _actionStart) {
      if (!state.isRunning) await state.toggle();
      await _dismiss();
    } else {
      await _dismiss();
      await windowManager.show();
      await windowManager.focus();
    }
  }
}
