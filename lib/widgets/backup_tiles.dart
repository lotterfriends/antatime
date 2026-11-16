import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../csv_export.dart';
import '../format.dart';
import '../models.dart';
import '../repository.dart';

/// Export und Import aller Daten und Einstellungen als JSON-Datei.
class BackupTiles extends StatelessWidget {
  const BackupTiles({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('Exportieren'),
          subtitle: const Text(
              'Arbeitszeiten, Abwesenheiten und Einstellungen als Datei sichern'),
          onTap: () => _export(context),
        ),
        ListTile(
          leading: const Icon(Icons.table_chart_outlined),
          title: const Text('Als CSV exportieren'),
          subtitle: const Text(
              'Arbeitszeiten eines Zeitraums als Tabelle, z. B. für Excel'),
          onTap: () => _exportCsv(context),
        ),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('Importieren'),
          subtitle: const Text('Ersetzt alle Daten durch eine Sicherung'),
          onTap: () => _import(context),
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final fileName = 'antatime-${dayKey(now)}.json';
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Export speichern',
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(state.exportJson())),
        mimeType: 'application/json',
      );
      if (uri == null) return;
      messenger.showSnackBar(const SnackBar(content: Text('Export gespeichert')));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Export fehlgeschlagen: $e')));
    }
  }

  Future<void> _exportCsv(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final today = dayOf(DateTime.now());
    final range = await showDateRangePicker(
      context: context,
      helpText: 'Zeitraum für den CSV-Export',
      saveText: 'Weiter',
      // Vorschlag: aktueller Monat bis heute.
      initialDateRange:
          DateTimeRange(start: DateTime(today.year, today.month), end: today),
      firstDate: DateTime(2000),
      lastDate: DateTime(today.year + 3, 12, 31),
    );
    if (range == null) return;
    final from = dayOf(range.start);
    final to = dayOf(range.end);
    final csv = exportCsv(state.data, from, to);
    final fileName = 'antatime-${dayKey(from)}-bis-${dayKey(to)}.csv';
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'CSV-Export speichern',
        fileName: fileName,
        // Mit BOM, damit Excel die Umlaute als UTF-8 erkennt.
        bytes: Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]),
        mimeType: 'text/csv',
      );
      if (uri == null) return;
      messenger.showSnackBar(SnackBar(
          content: Text('CSV-Export gespeichert '
              '(${formatDateShort(from)} – ${formatDateShort(to)})')));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('CSV-Export fehlgeschlagen: $e')));
    }
  }

  Future<void> _import(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final AppData imported;
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Sicherung wählen');
      if (files.isEmpty) return;
      final text = utf8.decode(await files.first.readAsBytes());
      imported = Repository.importJson(text);
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Import fehlgeschlagen: $e')));
      return;
    }
    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sicherung importieren?'),
        content: Text(
          'Die Sicherung enthält ${imported.sessions.length} Arbeitszeiten und '
          '${imported.absences.length} Abwesenheiten.\n\n'
          'Alle vorhandenen Daten und Einstellungen werden ersetzt.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Importieren')),
        ],
      ),
    );
    if (ok != true) return;
    await state.importData(imported);
    messenger.showSnackBar(const SnackBar(content: Text('Import abgeschlossen')));
  }
}
