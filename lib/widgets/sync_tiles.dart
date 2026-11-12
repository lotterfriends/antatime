import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../sync/sync_crypto.dart';
import '../sync/sync_service.dart';

/// Einstellungen der optionalen Synchronisation zwischen Geräten.
class SyncTiles extends StatelessWidget {
  const SyncTiles({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.read<AppState>().sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final notice = sync.notice;
        return Column(
          children: [
            if (notice != null)
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(notice),
                trailing: IconButton(
                  tooltip: 'Ausblenden',
                  icon: const Icon(Icons.close),
                  onPressed: sync.clearNotice,
                ),
              ),
            if (!sync.enabled)
              ListTile(
                leading: const Icon(Icons.sync_disabled),
                title: const Text('Geräte synchronisieren'),
                subtitle: const Text(
                    'Aus – die Daten bleiben nur auf diesem Gerät'),
                onTap: () => _setup(context, sync),
              )
            else ...[
              ListTile(
                leading: Icon(_statusIcon(sync.displayStatus)),
                title: Text(_statusText(sync.displayStatus)),
                subtitle: Text([
                  SyncService.wsUri(sync.url!).host,
                  if (sync.displayStatus == SyncStatus.offline &&
                      sync.error != null)
                    sync.error!,
                ].join(' · ')),
              ),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('Sync-Code anzeigen'),
                subtitle: const Text('Zum Einrichten weiterer Geräte'),
                onTap: () => _showCode(context, sync.code!),
              ),
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('Synchronisation beenden'),
                onTap: () => _disable(context, sync),
              ),
            ],
          ],
        );
      },
    );
  }

  static IconData _statusIcon(SyncStatus s) => switch (s) {
        SyncStatus.online || SyncStatus.otherTab => Icons.cloud_done_outlined,
        SyncStatus.connecting => Icons.cloud_sync_outlined,
        SyncStatus.offline || SyncStatus.off => Icons.cloud_off_outlined,
      };

  static String _statusText(SyncStatus s) => switch (s) {
        SyncStatus.online => 'Synchronisiert',
        SyncStatus.otherTab => 'Synchronisiert über einen anderen Tab',
        SyncStatus.connecting => 'Verbinde …',
        SyncStatus.offline => 'Offline – Änderungen werden später übertragen',
        SyncStatus.off => 'Aus',
      };

  Future<void> _setup(BuildContext context, SyncService sync) async {
    final result = await showDialog<_SetupResult>(
      context: context,
      builder: (_) => const _SetupDialog(),
    );
    if (result == null) return;
    await sync.enable(url: result.url, code: result.code, join: result.join);
    if (!result.join && context.mounted) {
      await _showCode(context, result.code, created: true);
    }
  }

  static Future<void> _showCode(BuildContext context, String code,
      {bool created = false}) {
    final formatted = SyncCrypto.formatCode(code);
    return showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(created ? 'Sync eingerichtet' : 'Sync-Code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Diesen Code auf weiteren Geräten unter '
                '„Geräte synchronisieren → Vorhandener Code“ eingeben:'),
            const SizedBox(height: 16),
            SelectableText(
              formatted,
              style: Theme.of(c)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontFamily: 'monospace', letterSpacing: 1),
            ),
            const SizedBox(height: 16),
            Text(
              'Der Code ist der einzige Schlüssel zu deinen Daten: Sie werden '
              'damit auf dem Gerät verschlüsselt, der Server kann sie nicht '
              'lesen. Gib ihn nicht weiter – und bewahre ihn auf, ohne Code '
              'lassen sich die Daten nicht wiederherstellen.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Kopieren'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: formatted));
              if (c.mounted) {
                ScaffoldMessenger.of(c).showSnackBar(
                    const SnackBar(content: Text('Code kopiert')));
              }
            },
          ),
          FilledButton(
              onPressed: () => Navigator.pop(c), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _disable(BuildContext context, SyncService sync) async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Synchronisation beenden?'),
        content: const Text(
            'Die Daten auf diesem Gerät bleiben erhalten.\n\n'
            'Optional können auch alle Daten auf dem Server gelöscht werden. '
            'Dann endet die Synchronisation auf allen Geräten und der Code '
            'ist nicht mehr verwendbar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Auch auf dem Server löschen')),
          FilledButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Nur hier beenden')),
        ],
      ),
    );
    if (choice == null) return;
    final ok = await sync.disable(deleteRemote: choice);
    if (!ok) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Keine Verbindung zum Server – nichts gelöscht.')));
    }
  }
}

class _SetupResult {
  const _SetupResult(this.url, this.code, this.join);
  final String url;
  final String code;
  final bool join;
}

class _SetupDialog extends StatefulWidget {
  const _SetupDialog();

  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  final _url = TextEditingController(text: SyncService.suggestedUrl);
  final _code = TextEditingController();
  bool _join = false;
  String? _urlError;
  String? _codeError;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    String? urlError;
    if (url.isEmpty) {
      urlError = 'Bitte die Adresse des Servers angeben';
    } else {
      try {
        final u = SyncService.wsUri(url);
        if (u.host.isEmpty || !(u.scheme == 'ws' || u.scheme == 'wss')) {
          urlError = 'Ungültige Adresse';
        }
      } on FormatException {
        urlError = 'Ungültige Adresse';
      }
    }
    String? code;
    String? codeError;
    if (_join) {
      code = SyncCrypto.normalizeCode(_code.text);
      if (code == null) {
        codeError = 'Der Code hat ${SyncCrypto.codeLength} Zeichen';
      }
    } else {
      code = SyncCrypto.generateCode();
    }
    setState(() {
      _urlError = urlError;
      _codeError = codeError;
    });
    if (urlError != null || codeError != null) return;
    Navigator.pop(context, _SetupResult(url, code!, _join));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Geräte synchronisieren'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
                'Arbeitszeiten, Abwesenheiten und Einstellungen werden '
                'Ende-zu-Ende-verschlüsselt über einen AnTaTime-Server '
                'zwischen deinen Geräten abgeglichen.'),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Server',
                hintText: 'z. B. sync.example.org',
                errorText: _urlError,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Neuer Code')),
                ButtonSegment(value: true, label: Text('Vorhandener Code')),
              ],
              selected: {_join},
              onSelectionChanged: (v) => setState(() => _join = v.first),
            ),
            const SizedBox(height: 12),
            if (_join) ...[
              TextField(
                controller: _code,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Sync-Code',
                  hintText: 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX',
                  errorText: _codeError,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Text(
                'Die Daten werden zusammengeführt. Bei Abweichungen gilt '
                'der Stand vom Server.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else
              Text(
                'Es wird ein neuer Code erzeugt und alle Daten dieses Geräts '
                'werden hochgeladen.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(onPressed: _submit, child: const Text('Verbinden')),
      ],
    );
  }
}
