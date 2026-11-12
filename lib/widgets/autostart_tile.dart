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
  int? _until;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Autostart.instance.isEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
    final state = context.read<AppState>();
    state.autoTrack().then((v) {
      if (mounted) setState(() => _autoTrack = v);
    });
    state.autoTrackUntil().then((v) {
      if (mounted) setState(() => _until = v);
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

  Future<void> _setUntil(int? minutes) async {
    await context.read<AppState>().setAutoTrackUntil(minutes);
    if (mounted) setState(() => _until = minutes);
  }

  Future<void> _pickUntil() async {
    final initial = _until ?? 10 * 60;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
      helpText: 'Automatisch beginnen bis',
    );
    if (t != null) await _setUntil(t.hour * 60 + t.minute);
  }

  @override
  Widget build(BuildContext context) {
    final autoTrack = _autoTrack;
    final until = _until;
    final always = autoTrack == AutoTrack.always;
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
          ListTile(
            leading: const SizedBox(width: 24),
            enabled: !always,
            title: const Text('Nur bis'),
            subtitle: Text(always
                ? '„Immer beginnen“ ist eingeschaltet und gilt zu jeder Uhrzeit'
                : until == null
                    ? 'Zu jeder Uhrzeit automatisch beginnen'
                    : 'Bei einem späteren Start nicht mehr automatisch '
                        'beginnen'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(until == null ? 'Ohne Grenze' : '${_hm(until)} Uhr'),
                if (until != null)
                  IconButton(
                    tooltip: 'Ohne Grenze',
                    icon: const Icon(Icons.clear),
                    onPressed: always ? null : () => _setUntil(null),
                  ),
              ],
            ),
            onTap: _pickUntil,
          ),
        if (autoTrack != null && autoTrack != AutoTrack.off)
          SwitchListTile(
            secondary: const SizedBox(width: 24),
            title: const Text('Immer beginnen'),
            subtitle: const Text('Bei jedem Start, auch an freien Tagen '
                'und unabhängig von der Uhrzeit'),
            value: autoTrack == AutoTrack.always,
            onChanged: (v) =>
                _setAutoTrack(v ? AutoTrack.always : AutoTrack.workdays),
          ),
      ],
    );
  }
}

String _hm(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

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
