import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'balance.dart';
import 'format.dart';
import 'models.dart';
import 'tray_icon_style.dart';

/// Steuerung über den Infobereich (System-Tray) der Desktop-Version –
/// das Gegenstück zur Benachrichtigung auf Android, ohne Animationen.
///
/// - Symbol: laufend Uhr mit Pfeil (grün), pausiert Stoppuhr mit Pause (grau);
///   unter Linux/Windows wahlweise einfarbig hell/dunkel ([TrayIconStyle])
/// - Menü: „Derzeit“/„Pause“ und „Heute“ (minutengenau), Start/Pause,
///   Feierabend, Fenster öffnen, Beenden
/// - Solange das Symbol aktiv ist, versteckt das Schließen des Fensters die
///   App nur im Infobereich; „Beenden“ im Menü beendet sie.
///
/// Ein-/ausschalten über dieselbe Einstellung wie die Benachrichtigung
/// (`Settings.showNotification`).
class TrayService with TrayListener, WindowListener {
  TrayService._();
  static final instance = TrayService._();

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Darstellung wählbar ([TrayIconStyle]); macOS passt das Symbol selbst
  /// der Menüleiste an.
  static bool get iconStyleSupported => supported && !_isMacOS;

  static bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;
  static bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  static const _kToggle = 'toggle';
  static const _kFinish = 'finish';
  static const _kOpen = 'open';
  static const _kQuit = 'quit';

  AppState? _state;
  bool _active = false;
  bool _quitting = false;
  String? _icon;

  /// Zuletzt angezeigter Zustand; das Menü wird nur bei Änderungen neu
  /// gesetzt (die App meldet sich jede Sekunde, die Texte ändern sich
  /// höchstens einmal pro Minute).
  _TrayModel? _shown;
  Future<void> _pending = Future.value();

  /// Vor `runApp` aufrufen.
  static Future<void> ensureInitialized() async {
    if (!supported) return;
    await windowManager.ensureInitialized();
  }

  Future<void> attach(AppState state) async {
    if (!supported || _state != null) return;
    _state = state;
    trayManager.addListener(this);
    windowManager.addListener(this);
    state.addListener(_onStateChanged);
    _onStateChanged();
  }

  void _onStateChanged() {
    final state = _state;
    if (state == null || _quitting) return;
    final model = _TrayModel.of(state, DateTime.now());
    if (model == _shown) return;
    _shown = model;
    // Nacheinander ausführen, damit sich Aufrufe nicht überholen.
    _pending = _pending.then((_) => _apply(model)).catchError((Object e) {
      debugPrint('Infobereich: $e');
    });
  }

  Future<void> _apply(_TrayModel m) async {
    if (!m.enabled) {
      if (_active) {
        _active = false;
        _icon = null;
        await trayManager.destroy();
      }
      await windowManager.setPreventClose(false);
      return;
    }
    _active = true;
    final name = '${m.running ? 'running' : 'paused'}'
        '${_isMacOS ? '_template' : m.iconStyle.suffix}';
    if (_icon != name) {
      _icon = name;
      await trayManager.setIcon(
        'assets/tray/$name.${_isWindows ? 'ico' : 'png'}',
        isTemplate: _isMacOS,
      );
    }
    // Tooltips gibt es unter Linux (AppIndicator) nicht.
    if (defaultTargetPlatform != TargetPlatform.linux) {
      await trayManager.setToolTip('AnTaTime – ${m.status}\n${m.today}');
    }
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(label: m.current, disabled: true),
      MenuItem(label: m.today, disabled: true),
      MenuItem.separator(),
      MenuItem(key: _kToggle, label: m.running ? 'Pause' : 'Start'),
      MenuItem(key: _kFinish, label: 'Feierabend', disabled: m.finished),
      MenuItem.separator(),
      MenuItem(key: _kOpen, label: 'AnTaTime öffnen'),
      MenuItem(key: _kQuit, label: 'Beenden'),
    ]));
    await windowManager.setPreventClose(true);
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // --- TrayListener ----------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    // Windows: Linksklick öffnet das Fenster, Rechtsklick das Menü.
    // macOS: Menüleisten-Symbole öffnen üblicherweise ihr Menü.
    // Linux (AppIndicator): jeder Klick öffnet das Menü, ohne Ereignis hier.
    if (_isMacOS) {
      trayManager.popUpContextMenu();
    } else {
      _showWindow();
    }
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final state = _state;
    if (state == null) return;
    switch (menuItem.key) {
      case _kToggle:
        state.toggle();
      case _kFinish:
        state.finishDay();
      case _kOpen:
        _showWindow();
      case _kQuit:
        _quit();
    }
  }

  // --- WindowListener --------------------------------------------------------

  /// Nur aktiv, solange `setPreventClose(true)` gilt, also mit Tray-Symbol.
  @override
  void onWindowClose() {
    if (_quitting) return;
    if (_active) {
      windowManager.hide();
    } else {
      _quit();
    }
  }

  Future<void> _quit() async {
    _quitting = true;
    _state?.removeListener(_onStateChanged);
    try {
      await _pending;
      if (_active) await trayManager.destroy();
    } finally {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }
}

/// Alles, was im Infobereich angezeigt wird.
@immutable
class _TrayModel {
  const _TrayModel({
    required this.enabled,
    required this.iconStyle,
    required this.running,
    required this.finished,
    required this.status,
    required this.current,
    required this.today,
  });

  factory _TrayModel.of(AppState state, DateTime now) {
    final data = state.data;
    final running = data.running;
    final stats = BalanceCalculator(data, now).statsFor(now);
    final today =
        'Heute: ${formatDuration(stats.worked)} von ${formatDuration(stats.target)}';
    final String current;
    if (running != null) {
      current = 'Derzeit: ${formatDuration(now.difference(running.start))}'
          ' (seit ${formatTime(running.start)})';
    } else if (state.stoppedToday) {
      current = 'Feierabend';
    } else {
      final lastEnd = _lastEndToday(data, now);
      current = lastEnd == null
          ? 'Bereit'
          : 'Pause: ${formatDuration(now.difference(lastEnd))}';
    }
    return _TrayModel(
      enabled: data.settings.showNotification,
      iconStyle: state.trayIconStyle,
      running: running != null,
      finished: running == null && state.stoppedToday,
      status: running != null ? 'Arbeitszeit läuft' : 'Pausiert',
      current: current,
      today: today,
    );
  }

  static DateTime? _lastEndToday(AppData data, DateTime now) {
    DateTime? last;
    for (final s in data.sessions) {
      final end = s.end;
      if (end == null ||
          end.year != now.year ||
          end.month != now.month ||
          end.day != now.day ||
          end.isAfter(now)) {
        continue;
      }
      if (last == null || end.isAfter(last)) last = end;
    }
    return last;
  }

  final bool enabled;
  final TrayIconStyle iconStyle;
  final bool running;
  final bool finished;
  final String status;
  final String current;
  final String today;

  @override
  bool operator ==(Object other) =>
      other is _TrayModel &&
      other.enabled == enabled &&
      other.iconStyle == iconStyle &&
      other.running == running &&
      other.finished == finished &&
      other.status == status &&
      other.current == current &&
      other.today == today;

  @override
  int get hashCode =>
      Object.hash(
          enabled, iconStyle, running, finished, status, current, today);
}
