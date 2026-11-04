import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'balance.dart';
import 'format.dart';
import 'models.dart';
import 'repository.dart';

const _notificationId = 1;
const _channelId = 'tracking';
const _actionToggle = 'toggle';
const _categoryRunning = 'running';
const _categoryPaused = 'paused';

/// Wird ausgeführt, wenn in der Benachrichtigung „Start“/„Pause“ gedrückt
/// wird, während die App im Hintergrund ist oder beendet wurde.
@pragma('vm:entry-point')
Future<void> notificationActionBackground(NotificationResponse response) async {
  if (response.actionId != _actionToggle) return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final repo = Repository();
  final data = await repo.load();
  Repository.toggle(data, DateTime.now());
  await repo.saveSessions(data.sessions);
  await NotificationService.instance.init();
  await NotificationService.instance.update(data);
}

/// Steuerung der Arbeitszeit über den Benachrichtigungsbereich
/// (Android & iOS; im Browser nicht verfügbar).
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Wird aufgerufen, wenn die Aktion im Vordergrund ausgelöst wird.
  VoidCallback? onToggle;

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> init() async {
    if (!supported || _initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(_categoryRunning, actions: [
          DarwinNotificationAction.plain(_actionToggle, 'Pause'),
        ]),
        DarwinNotificationCategory(_categoryPaused, actions: [
          DarwinNotificationAction.plain(_actionToggle, 'Start'),
        ]),
      ],
    );
    await _plugin.initialize(
      settings: InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: (r) {
        if (r.actionId == _actionToggle) onToggle?.call();
      },
      onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
    );
    _initialized = true;
  }

  Future<void> requestPermission() async {
    if (!supported || !_initialized) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: false, sound: false);
  }

  Future<void> cancel() async {
    if (!supported || !_initialized) return;
    await _plugin.cancel(id: _notificationId);
  }

  /// Zeigt/aktualisiert die Steuer-Benachrichtigung passend zum Zustand.
  Future<void> update(AppData data) async {
    if (!supported || !_initialized) return;
    if (!data.settings.showNotification) {
      await cancel();
      return;
    }
    final now = DateTime.now();
    final calc = BalanceCalculator(data, now);
    final today = calc.statsFor(now);
    final running = data.running;
    final isRunning = running != null;

    final title = isRunning ? 'Arbeitszeit läuft' : 'Pausiert';
    final body = isRunning
        ? 'Seit ${formatTime(running.start)} · Soll heute ${formatDuration(today.target)}'
        : 'Heute gearbeitet: ${formatDuration(today.worked)} von ${formatDuration(today.target)}';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      'Zeiterfassung',
      channelDescription: 'Start/Pause der Arbeitszeit',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: isRunning,
      autoCancel: false,
      onlyAlertOnce: true,
      playSound: false,
      enableVibration: false,
      showWhen: isRunning,
      // Chronometer zeigt die gesamte heutige Arbeitszeit live an.
      usesChronometer: isRunning,
      when: isRunning
          ? now.millisecondsSinceEpoch - today.worked.inMilliseconds
          : null,
      category: AndroidNotificationCategory.status,
      actions: [
        AndroidNotificationAction(
          _actionToggle,
          isRunning ? 'Pause' : 'Start',
          cancelNotification: false,
        ),
      ],
    );
    final darwinDetails = DarwinNotificationDetails(
      categoryIdentifier: isRunning ? _categoryRunning : _categoryPaused,
      presentSound: false,
      presentBadge: false,
    );

    await _plugin.show(
      id: _notificationId,
      title: title,
      body: body,
      notificationDetails:
          NotificationDetails(android: androidDetails, iOS: darwinDetails),
    );
  }
}
