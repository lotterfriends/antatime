import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../auto_track.dart';
import '../desktop/autostart.dart';
import '../desktop/desktop_notifications.dart';

/// Desktop: Schalter „Mit dem System starten“ und „Zeiterfassung beim Start
/// beginnen“. Beides gilt nur für dieses Gerät und wird nicht
/// synchronisiert; der Autostart wird beim System abgefragt.
class AutostartTile extends StatefulWidget {
  const AutostartTile({super.key});

  @override
  State<AutostartTile> createState() => _AutostartTileState();
}

class _AutostartTileState extends State<AutostartTile> {
  bool? _enabled;
  AutoTrack? _autoTrack;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Autostart.instance.isEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
    context.read<AppState>().autoTrack().then((v) {
      if (mounted) setState(() => _autoTrack = v);
    });
  }

  Future<void> _set(bool value) async {
    setState(() => _busy = true);
    String? error;
    try {
      await Autostart.instance.setEnabled(value);
      if (value) await DesktopNotifications.instance.requestPermission();
    } on Exception catch (e) {
      error = e.toString();
    }
    final actual = await Autostart.instance.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = actual;
      _busy = false;
    });
    if (error != null || actual != value) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Autostart konnte nicht geändert werden'
            '${error != null ? ': $error' : ''}'),
      ));
      return;
    }
    // Beim Einschalten fragen, ob die Zeiterfassung dann auch gleich
    // beginnen soll – sofern das nicht schon eingestellt ist.
    if (value && _autoTrack == AutoTrack.off) {
      final mode = await _askAutoTrack(context);
      if (mode != null && mode != AutoTrack.off) await _setAutoTrack(mode);
    }
  }

  Future<void> _setAutoTrack(AutoTrack mode) async {
    await context.read<AppState>().setAutoTrack(mode);
    if (mounted) setState(() => _autoTrack = mode);
  }

  @override
  Widget build(BuildContext context) {
    final autoTrack = _autoTrack;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.power_settings_new),
          title: const Text('Mit dem System starten'),
          subtitle: Text(autoTrack == AutoTrack.off
              ? 'AnTaTime startet bei der Anmeldung im Infobereich und '
                  'fragt per Benachrichtigung, ob die Zeiterfassung '
                  'beginnen soll'
              : 'AnTaTime startet bei der Anmeldung im Infobereich'),
          value: _enabled ?? false,
          onChanged: _enabled == null || _busy ? null : _set,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.play_circle_outline),
          title: const Text('Zeiterfassung beim Start beginnen'),
          subtitle: const Text('Beim Öffnen von AnTaTime an Arbeitstagen '
              'automatisch starten (nicht an Feiertagen, bei Abwesenheit '
              'und nach Feierabend)'),
          value: autoTrack != null && autoTrack != AutoTrack.off,
          onChanged: autoTrack == null
              ? null
              : (v) => _setAutoTrack(v ? AutoTrack.workdays : AutoTrack.off),
        ),
        if (autoTrack != null && autoTrack != AutoTrack.off)
          SwitchListTile(
            secondary: const SizedBox(width: 24),
            title: const Text('Immer beginnen'),
            subtitle: const Text('Bei jedem Start, auch an freien Tagen'),
            value: autoTrack == AutoTrack.always,
            onChanged: (v) =>
                _setAutoTrack(v ? AutoTrack.always : AutoTrack.workdays),
          ),
      ],
    );
  }
}

/// Fragt nach dem Einschalten des Autostarts, ob die Zeiterfassung beim
/// Start auch gleich beginnen soll (`null` = abgebrochen).
Future<AutoTrack?> _askAutoTrack(BuildContext context) {
  return showDialog<AutoTrack>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Zeiterfassung gleich starten?'),
      content: const Text('Soll die Zeiterfassung beim Start von AnTaTime '
          'auch direkt beginnen?\n\n'
          'An Arbeitstagen: nicht an freien Tagen, Feiertagen, bei '
          'Abwesenheit und nach Feierabend.\n'
          'Immer: bei jedem Start.\n\n'
          'Das lässt sich in den Einstellungen jederzeit ändern.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, AutoTrack.off),
            child: const Text('Nein')),
        TextButton(
            onPressed: () => Navigator.pop(c, AutoTrack.always),
            child: const Text('Immer')),
        FilledButton(
            onPressed: () => Navigator.pop(c, AutoTrack.workdays),
            child: const Text('An Arbeitstagen')),
      ],
    ),
  );
}
