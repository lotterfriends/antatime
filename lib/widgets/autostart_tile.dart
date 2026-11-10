import 'package:flutter/material.dart';

import '../desktop/autostart.dart';
import '../desktop/start_prompt.dart';

/// Schalter „Mit dem System starten“ (Desktop). Der Zustand wird nicht in den
/// Einstellungen gespeichert, sondern beim System abgefragt – er gilt nur für
/// dieses Gerät und wird nicht synchronisiert.
class AutostartTile extends StatefulWidget {
  const AutostartTile({super.key});

  @override
  State<AutostartTile> createState() => _AutostartTileState();
}

class _AutostartTileState extends State<AutostartTile> {
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Autostart.instance.isEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  Future<void> _set(bool value) async {
    setState(() => _busy = true);
    String? error;
    try {
      await Autostart.instance.setEnabled(value);
      if (value) await StartPrompt.instance.requestPermission();
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.power_settings_new),
      title: const Text('Mit dem System starten'),
      subtitle: const Text('AnTaTime startet bei der Anmeldung im '
          'Infobereich und fragt per Benachrichtigung, ob die '
          'Zeiterfassung beginnen soll'),
      value: _enabled ?? false,
      onChanged: _enabled == null || _busy ? null : _set,
    );
  }
}
