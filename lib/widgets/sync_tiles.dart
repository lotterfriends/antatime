import 'package:flutter/foundation.dart';
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
              if (sync.problem case final problem?)
                ListTile(
                  leading: Icon(Icons.error_outline,
                      color: Theme.of(context).colorScheme.error),
                  title: Text(problem.title),
                  subtitle: Text([
                    SyncService.wsUri(sync.url!).host,
                    sync.error ?? problem.text,
                  ].join(' · ')),
                  onTap: problem.isKey
                      ? () => _editServerKey(context, sync)
                      : null,
                )
              else
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
              if (sync.clockWarning != null)
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('Geräteuhr geht falsch'),
                  subtitle: Text(sync.clockWarning!),
                ),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('Sync-Code anzeigen'),
                subtitle: const Text('Zum Einrichten weiterer Geräte'),
                onTap: () => _showCode(context, sync.code!),
              ),
              ListTile(
                leading: const Icon(Icons.vpn_key_outlined),
                title: const Text('Server-Schlüssel'),
                subtitle: Text(sync.serverKey == null
                    ? 'Nicht eingetragen – nur nötig, wenn der Server eine '
                        'Anmeldung verlangt'
                    : 'Eingetragen'),
                onTap: () => _editServerKey(context, sync),
              ),
              if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                const _BackgroundSyncTile(),
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
    await sync.enable(
        url: result.url,
        code: result.code,
        join: result.join,
        serverKey: result.serverKey);
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

  /// Server-Schlüssel eintragen, ändern oder entfernen.
  static Future<void> _editServerKey(
      BuildContext context, SyncService sync) async {
    final result = await showDialog<_ServerKeyResult>(
      context: context,
      builder: (_) => _ServerKeyDialog(current: sync.serverKey),
    );
    if (result == null) return;
    await sync.setServerKey(result.key);
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
  const _SetupResult(this.url, this.code, this.join, this.serverKey);
  final String url;
  final String code;
  final bool join;
  final String? serverKey;
}

const _serverKeyHint = 'XXXX-XXXX-XXXX-…';
const _serverKeyLengthError =
    'Der Server-Schlüssel hat ${ServerKey.textLength} Zeichen';

/// `key == null`: Schlüssel entfernen.
class _ServerKeyResult {
  const _ServerKeyResult(this.key);
  final String? key;
}

class _ServerKeyDialog extends StatefulWidget {
  const _ServerKeyDialog({this.current});
  final String? current;

  @override
  State<_ServerKeyDialog> createState() => _ServerKeyDialogState();
}

class _ServerKeyDialogState extends State<_ServerKeyDialog> {
  late final _key = TextEditingController(
      text: widget.current == null ? '' : ServerKey.format(widget.current!));
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _submit() {
    final key = ServerKey.normalize(_key.text);
    if (key == null) {
      setState(() => _error = _serverKeyLengthError);
      return;
    }
    Navigator.pop(context, _ServerKeyResult(key));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server-Schlüssel'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
                'Manche Server nehmen nur Geräte an, die den Schlüssel des '
                'Servers kennen. Du bekommst ihn vom Betreiber. Er gilt nur '
                'für dieses Gerät und wird nicht synchronisiert.'),
            const SizedBox(height: 16),
            TextField(
              controller: _key,
              autofocus: true,
              autocorrect: false,
              minLines: 1,
              maxLines: 3,
              // Mehrzeilig nur zur Anzeige: Enter bestätigt.
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Server-Schlüssel',
                hintText: _serverKeyHint,
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        if (widget.current != null)
          TextButton(
              onPressed: () =>
                  Navigator.pop(context, const _ServerKeyResult(null)),
              child: const Text('Entfernen')),
        FilledButton(onPressed: _submit, child: const Text('Speichern')),
      ],
    );
  }
}

class _SetupDialog extends StatefulWidget {
  const _SetupDialog();

  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  final _url = TextEditingController(text: SyncService.suggestedUrl);
  final _code = TextEditingController();
  final _key = TextEditingController();
  bool _join = false;
  String? _urlError;
  String? _codeError;
  String? _keyError;

  /// Meldung des Servers, die zu keinem Feld gehört (z. B. „Server ist voll“).
  String? _serverError;

  /// Die Verbindung wird gerade geprüft.
  bool _checking = false;

  /// Für diese Eingaben war der Server nicht erreichbar: Ein zweiter Versuch
  /// richtet trotzdem ein (der Abgleich beginnt dann später).
  String? _unreachableFor;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
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
    String? serverKey;
    String? keyError;
    if (_key.text.trim().isNotEmpty) {
      serverKey = ServerKey.normalize(_key.text);
      if (serverKey == null) keyError = _serverKeyLengthError;
    }
    setState(() {
      _urlError = urlError;
      _codeError = codeError;
      _keyError = keyError;
      _serverError = null;
    });
    if (urlError != null || codeError != null || keyError != null) return;
    final result = _SetupResult(url, code!, _join, serverKey);

    // Vor dem Einrichten fragen, ob der Server diesen Zugang annimmt – sonst
    // stünde die Absage (Server voll, Schlüssel) erst später in den
    // Einstellungen.
    final attempt = '$url|${_join ? code : ''}|$serverKey';
    if (_unreachableFor == attempt) {
      Navigator.pop(context, result);
      return;
    }
    setState(() => _checking = true);
    final check =
        await SyncService.check(url: url, code: code, serverKey: serverKey);
    if (!mounted) return;
    if (check.ok) {
      Navigator.pop(context, result);
      return;
    }
    setState(() {
      _checking = false;
      if (check.unreachable) {
        _unreachableFor = attempt;
        _serverError = 'Der Server ist nicht erreichbar. Bitte die Adresse '
            'prüfen – oder erneut auf „Verbinden“ tippen, um trotzdem '
            'einzurichten. Der Abgleich beginnt dann, sobald der Server '
            'erreichbar ist.';
      } else if (check.problem?.isKey ?? false) {
        _keyError = check.message;
      } else {
        _serverError = check.message;
      }
    });
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
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              autocorrect: false,
              minLines: 1,
              maxLines: 3,
              // Mehrzeilig nur zur Anzeige: Enter bestätigt.
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Server-Schlüssel (optional)',
                hintText: _serverKeyHint,
                helperText: 'Nur nötig, wenn der Server eine Anmeldung '
                    'verlangt',
                helperMaxLines: 2,
                errorText: _keyError,
                errorMaxLines: 4,
              ),
              onSubmitted: (_) => _submit(),
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
            if (_serverError != null) ...[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 20, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _serverError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(
          onPressed: _checking ? null : _submit,
          child: Text(_checking ? 'Prüfe …' : 'Verbinden'),
        ),
      ],
    );
  }
}

/// Android: Sync im Hintergrund, damit die Benachrichtigung Änderungen
/// anderer Geräte sofort zeigt (nur dieses Gerät).
class _BackgroundSyncTile extends StatelessWidget {
  const _BackgroundSyncTile();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SwitchListTile(
        secondary: const Icon(Icons.sync_outlined),
        title: const Text('Im Hintergrund synchronisieren'),
        subtitle: const Text('Hält die Verbindung, solange die '
            'Benachrichtigung sichtbar ist, damit Start/Pause auf anderen '
            'Geräten sofort erscheint; sonst etwa alle 15 Minuten. '
            'Erhöht den Akkuverbrauch.'),
        value: state.backgroundSync,
        onChanged: state.setBackgroundSync,
      ),
    );
  }
}
