import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../update/update_manifest.dart';
import '../update/update_service.dart';

/// Einstellungen → Updates: nach einer neuen Version suchen und sie
/// installieren (Android-APK und Desktop, siehe [UpdateService]).
class UpdateTiles extends StatelessWidget {
  const UpdateTiles({super.key, this.service});

  /// Für Tests; sonst [UpdateService.instance].
  final UpdateService? service;

  @override
  Widget build(BuildContext context) {
    final updates = service ?? UpdateService.instance;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final found = updates.available;
        final error = updates.error;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (found != null)
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: Text('Version ${found.version} ist verfügbar'),
                subtitle: _progress(updates) ??
                    Text('Installiert: ${updates.currentVersion ?? '–'} · '
                        '${_megabytes(found.size)}'),
                trailing: updates.busy
                    ? null
                    : FilledButton(
                        onPressed: () => _install(context, updates, found),
                        child: Text(updates.kind == UpdateKind.dmg
                            ? 'Herunterladen'
                            : 'Installieren'),
                      ),
              )
            else
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('Nach Updates suchen'),
                subtitle: Text(_checkedText(updates)),
                trailing: updates.status == UpdateStatus.checking
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: updates.busy ? null : () => _check(context, updates),
              ),
            if (error != null)
              ListTile(
                leading: Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error),
                title: Text(error),
              ),
            SwitchListTile(
              secondary: const Icon(Icons.update),
              title: const Text('Automatisch nach Updates suchen'),
              subtitle: Text('Fragt gelegentlich bei ${updates.serverHost} '
                  'nach; installiert wird erst nach Bestätigung'),
              value: updates.auto,
              onChanged: updates.setAuto,
            ),
          ],
        );
      },
    );
  }

  static Widget? _progress(UpdateService updates) => switch (updates.status) {
        UpdateStatus.downloading => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Wird heruntergeladen … '
                  '${(updates.progress * 100).round()} %'),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: updates.progress),
            ],
          ),
        UpdateStatus.installing => const Text('Wird installiert …'),
        _ => null,
      };

  static String _checkedText(UpdateService updates) {
    final version = 'Installiert: ${updates.currentVersion ?? '–'}';
    final last = updates.lastCheck;
    if (updates.status == UpdateStatus.checking) return '$version · Suche …';
    if (last == null) return version;
    return '$version · aktuell (geprüft am '
        '${DateFormat('d. MMM, HH:mm', 'de_DE').format(last)})';
  }

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB';

  static Future<void> _check(BuildContext context, UpdateService updates) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await updates.check();
    if (ok && updates.available == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('AnTaTime ist auf dem neuesten Stand')));
    }
  }

  static Future<void> _install(
      BuildContext context, UpdateService updates, UpdatePackage found) async {
    final how = switch (updates.kind) {
      UpdateKind.apk => 'Nach dem Herunterladen fragt Android, ob die App '
          'aktualisiert werden soll. Beim ersten Mal muss AnTaTime dafür '
          'das Installieren von Apps erlaubt werden.',
      UpdateKind.deb => 'Für die Installation fragt das System nach dem '
          'Passwort. Danach startet AnTaTime neu.',
      UpdateKind.exe => 'Danach wird AnTaTime beendet, das Setup läuft '
          'durch und AnTaTime startet neu.',
      UpdateKind.dmg => 'Der Browser lädt das Disk-Image. Danach AnTaTime '
          'beenden, das Disk-Image öffnen und die App im Ordner „Programme“ '
          'durch die neue ersetzen.',
      _ => 'Danach startet AnTaTime neu.',
    };
    final manual = updates.kind == UpdateKind.dmg;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('AnTaTime ${found.version} '
            '${manual ? 'herunterladen' : 'installieren'}?'),
        content: Text('${_megabytes(found.size)} werden heruntergeladen. $how\n\n'
            'Erfasste Zeiten und Einstellungen bleiben erhalten.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Später')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(manual ? 'Herunterladen' : 'Installieren')),
        ],
      ),
    );
    if (go == true) await updates.install();
  }
}
