import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'balance.dart';
import 'format.dart';
import 'models.dart';
import 'reminder.dart';
import 'repository.dart';

const _notificationId = 1;
const _channelId = 'tracking';
/// Ältere Benachrichtigungen schalten um; neue sagen, was gemeint ist
/// ([_actionStart]/[_actionPause]) – der angezeigte Zustand kann veraltet
/// sein (z. B. inzwischen auf einem anderen Gerät gestartet).
const _actionToggle = 'toggle';
const _actionPause = 'pause';
const _categoryRunning = 'running';
const _categoryPaused = 'paused';

/// Erinnerung an den Start der Zeiterfassung (iOS; Android nativ, siehe
/// ReminderScheduler.kt). IDs 100–163 für die geplanten Erinnerungen.
const _reminderIdBase = 100;
const _reminderMaxCount = 64;
const _reminderChannelId = 'reminder';
const _actionStart = 'start';
const _categoryReminder = 'reminder';

/// Erinnerung beim Erreichen der Tagesstunden (iOS; Android nativ, siehe
/// TargetReminder.kt).
const _targetId = 200;
const _actionFinish = 'finish';
const _categoryTarget = 'target';

/// Wird ausgeführt, wenn in der Benachrichtigung „Start“/„Pause“ gedrückt
/// wird, während die App im Hintergrund ist oder beendet wurde.
@pragma('vm:entry-point')
Future<void> notificationActionBackground(NotificationResponse response) async {
  final action = response.actionId;
  if (action != _actionToggle &&
      action != _actionStart &&
      action != _actionPause &&
      action != _actionFinish) {
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final repo = Repository();
  final data = await repo.load();
  final now = DateTime.now();
  if (action == _actionFinish) {
    if (data.running != null) {
      Repository.toggle(data, now);
      await repo.saveSessions(data.sessions);
    }
    await repo.markStopped(now);
  } else if (action == _actionToggle ||
      (action == _actionStart && data.running == null) ||
      (action == _actionPause && data.running != null)) {
    final started = Repository.toggle(data, now);
    await repo.saveSessions(data.sessions);
    if (started) await repo.clearStopped();
  }
  await NotificationService.instance.init();
  await NotificationService.instance.update(data);
}

/// Steuerung der Arbeitszeit über den Benachrichtigungsbereich
/// (Android & iOS; im Browser nicht verfügbar).
///
/// Android: eigene, native Benachrichtigung (TrackingNotification.kt) mit
/// animiertem Statusleisten-Symbol, Live-Uhren und Symbol-Aktionen.
/// iOS: flutter_local_notifications mit Start/Pause-Aktion.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  static const _native = MethodChannel('antatime/notification');
  bool _initialized = false;

  /// Wird aufgerufen, wenn die Aktion im Vordergrund ausgelöst wird (iOS).
  VoidCallback? onToggle;

  /// „Starten“ aus der Erinnerung im Vordergrund (iOS).
  VoidCallback? onStart;

  /// „Pause“ in der Benachrichtigung (iOS, im Vordergrund).
  VoidCallback? onPause;

  /// „Feierabend“ aus der Erinnerung an die Tagesstunden im Vordergrund (iOS).
  VoidCallback? onFinish;

  /// Wird aufgerufen, wenn die native Benachrichtigung die Daten geändert
  /// hat (Android).
  VoidCallback? onDataChanged;

  /// Die native Seite bittet um einen sofortigen Abgleich mit dem Server
  /// (regelmäßiger Hintergrund-Sync, Android).
  Future<void> Function()? onSyncNow;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> init() async {
    if (!supported || _initialized) return;
    if (_isAndroid) {
      _native.setMethodCallHandler((call) async {
        if (call.method == 'dataChanged') onDataChanged?.call();
        if (call.method == 'syncNow') await onSyncNow?.call();
      });
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(_categoryRunning, actions: [
          DarwinNotificationAction.plain(_actionPause, 'Pause'),
        ]),
        DarwinNotificationCategory(_categoryPaused, actions: [
          DarwinNotificationAction.plain(_actionStart, 'Start'),
        ]),
        DarwinNotificationCategory(_categoryReminder, actions: [
          DarwinNotificationAction.plain(_actionStart, 'Starten'),
        ]),
        DarwinNotificationCategory(_categoryTarget, actions: [
          DarwinNotificationAction.plain(_actionFinish, 'Feierabend'),
        ]),
      ],
    );
    await _plugin.initialize(
      settings: InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: (r) {
        if (r.actionId == _actionToggle) onToggle?.call();
        if (r.actionId == _actionPause) onPause?.call();
        if (r.actionId == _actionStart) onStart?.call();
        if (r.actionId == _actionFinish) onFinish?.call();
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
        ?.requestPermissions(alert: true, badge: false, sound: true);
  }

  /// Sync im Hintergrund ein-/ausschalten (Android): [active] = Sync
  /// eingerichtet und in den Einstellungen erlaubt.
  Future<void> setBackgroundSync(bool active) async {
    if (!supported || !_isAndroid) return;
    await _native.invokeMethod<void>('setBackgroundSync', active);
  }

  /// Meldet der nativen Seite, dass der Stand des Servers nach dem Start
  /// übernommen ist (oder das Warten darauf aufgegeben wurde).
  Future<void> reportSynced() async {
    if (!supported || !_isAndroid) return;
    await _native.invokeMethod<void>('synced');
  }

  Future<void> cancel() async {
    if (!supported || !_initialized) return;
    if (_isAndroid) {
      await _native.invokeMethod<void>('cancel');
    } else {
      await _plugin.cancel(id: _notificationId);
    }
  }

  /// Zeigt/aktualisiert die Steuer-Benachrichtigung passend zum Zustand.
  Future<void> update(AppData data) async {
    if (!supported || !_initialized) return;
    await _scheduleReminders(data);
    await _scheduleTargetReminder(data);
    if (_isAndroid) {
      // Die native Seite liest den Zustand selbst aus den gespeicherten Daten.
      await _native.invokeMethod<void>('refresh');
      return;
    }
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

  /// Plant die Erinnerungen an den Start der Zeiterfassung neu (siehe
  /// [reminderTimes]). Erinnerungen für heute entfallen, sobald gestartet
  /// wurde.
  Future<void> _scheduleReminders(AppData data) async {
    final now = DateTime.now();
    final times = reminderTimes(data, now);
    if (_isAndroid) {
      // Nativ (AlarmManager): prüft beim Auslösen selbst, ob schon
      // gestartet wurde – auch nach Start über die Benachrichtigung.
      await _native.invokeMethod<void>('scheduleReminders',
          times.map((t) => t.millisecondsSinceEpoch).toList());
      return;
    }
    // Nach dem Start auch die bereits angezeigte Erinnerung von heute
    // entfernen (cancel entfernt geplante und angezeigte).
    final key = '${startedOn(data, now)}|'
        '${times.map((t) => t.millisecondsSinceEpoch).join(',')}';
    if (key == _scheduledReminders) return;
    _scheduledReminders = key;
    for (var i = 0; i < _reminderMaxCount; i++) {
      await _plugin.cancel(id: _reminderIdBase + i);
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(_reminderChannelId, 'Erinnerung',
          channelDescription: 'Erinnerung an den Start der Zeiterfassung'),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: _categoryReminder,
        presentSound: true,
        presentBadge: false,
      ),
    );
    for (var i = 0; i < times.length && i < _reminderMaxCount; i++) {
      await _plugin.zonedSchedule(
        id: _reminderIdBase + i,
        // Absoluter Zeitpunkt; die lokale Uhrzeit wurde bereits berechnet.
        scheduledDate: tz.TZDateTime.from(times[i], tz.UTC),
        title: 'Zeiterfassung starten?',
        body: 'Die Arbeitszeit wurde heute noch nicht gestartet.',
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  /// Zuletzt geplante Erinnerungen (iOS), um unnötiges Neuplanen zu sparen.
  String? _scheduledReminders;

  /// Plant die Benachrichtigung beim Erreichen der Tagesstunden (siehe
  /// [targetReachedAt]); bei Pause entfällt sie, beim Fortsetzen wird neu
  /// geplant.
  Future<void> _scheduleTargetReminder(AppData data) async {
    final now = DateTime.now();
    if (_isAndroid) {
      // Nativ (AlarmManager): plant nach jedem Start/Pause selbst neu –
      // auch über die Benachrichtigung bei geschlossener App.
      await _native.invokeMethod<void>('scheduleTargetReminder', [
        for (final e in targetReminderDays(data, now).entries)
          '${dayKey(e.key)}=${e.value.inMilliseconds}',
      ]);
      return;
    }
    final at = targetReachedAt(data, now);
    final previous = _scheduledTarget;
    if (_targetPlanned && at == previous) return;
    _targetPlanned = true;
    _scheduledTarget = at;
    // Bereits angezeigte Benachrichtigung stehen lassen (cancel entfernt
    // auch angezeigte).
    final shown = previous != null && !previous.isAfter(now);
    if (!(at == null && shown)) await _plugin.cancel(id: _targetId);
    if (at == null) return;
    final target = BalanceCalculator(data, now).statsFor(now).target;
    await _plugin.zonedSchedule(
      id: _targetId,
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      title: 'Tagesstunden erreicht',
      body: 'Heute ${formatDuration(target)} h gearbeitet – Feierabend?',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(_reminderChannelId, 'Erinnerung',
            channelDescription: 'Erinnerung an den Start der Zeiterfassung'),
        iOS: DarwinNotificationDetails(
          categoryIdentifier: _categoryTarget,
          presentSound: true,
          presentBadge: false,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Zuletzt geplanter Zeitpunkt (iOS), um unnötiges Neuplanen zu sparen.
  DateTime? _scheduledTarget;
  bool _targetPlanned = false;
}
