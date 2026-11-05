import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../format.dart';
import '../models.dart';
import '../notification_service.dart';
import '../widgets/backup_tiles.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.data.settings;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: ListView(
        children: [
          _Section('Stundenkonto'),
          ListTile(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: const Text('Startwert'),
            subtitle: const Text('Übertrag beim Erfassungsbeginn'),
            trailing: Text('${formatSigned(Duration(minutes: s.startBalanceMinutes))} h',
                style: theme.textTheme.titleMedium),
            onTap: () async {
              final v = await _askHours(
                context,
                title: 'Startwert Stundenkonto',
                hint: 'z. B. 12:30 oder -4',
                initial: formatSigned(Duration(minutes: s.startBalanceMinutes))
                    .replaceAll('−', '-'),
                allowNegative: true,
              );
              if (v != null) {
                await state.updateSettings((x) => x.startBalanceMinutes = v);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Erfassungsbeginn'),
            subtitle: const Text('Ab diesem Tag wird das Konto berechnet'),
            trailing: Text(formatDateShort(s.startDate),
                style: theme.textTheme.titleMedium),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: s.startDate,
                firstDate: DateTime(2000),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d != null) await state.updateSettings((x) => x.startDate = d);
            },
          ),
          _Section('Arbeitszeit'),
          ListTile(
            leading: const Icon(Icons.date_range),
            title: const Text('Wochenstunden'),
            subtitle: const Text('Ändert die Tagesstunden entsprechend'),
            trailing: Text('${formatHoursNumber(s.weeklyHours)} h',
                style: theme.textTheme.titleMedium),
            onTap: () async {
              final v = await _askHours(context,
                  title: 'Wochenstunden',
                  hint: 'z. B. 40 oder 38:30',
                  initial: formatHoursNumber(s.weeklyHours));
              if (v != null) {
                await state.updateSettings((x) {
                  x.weeklyHours = v / 60;
                  if (x.workdays.isNotEmpty) {
                    x.dailyHours = x.weeklyHours / x.workdays.length;
                  }
                });
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.today),
            title: const Text('Tagesstunden'),
            subtitle: const Text('Soll pro Arbeitstag'),
            trailing: Text(
                '${formatDuration(Duration(minutes: s.dailyTargetMinutes))} h',
                style: theme.textTheme.titleMedium),
            onTap: () async {
              final v = await _askHours(context,
                  title: 'Tagesstunden',
                  hint: 'z. B. 8 oder 7:42',
                  initial:
                      formatDuration(Duration(minutes: s.dailyTargetMinutes)));
              if (v != null) {
                await state.updateSettings((x) {
                  x.dailyHours = v / 60;
                  x.weeklyHours = x.dailyHours * x.workdays.length;
                });
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Arbeitstage', style: theme.textTheme.bodyLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var wd = 1; wd <= 7; wd++)
                  FilterChip(
                    label: Text(weekdayShort[wd - 1]),
                    selected: s.workdays.contains(wd),
                    onSelected: (sel) => state.updateSettings((x) {
                      if (sel) {
                        x.workdays.add(wd);
                      } else {
                        x.workdays.remove(wd);
                      }
                      // Tagesstunden bleiben, Wochenstunden passen sich an.
                      x.weeklyHours = x.dailyHours * x.workdays.length;
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'An Arbeitstagen ohne Eintrag werden die Tagesstunden vom '
              'Stundenkonto abgezogen. Arbeit an freien Tagen zählt komplett '
              'als Überstunden.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.more_time),
            title: const Text('Faktor für Arbeit an Abwesenheitstagen'),
            subtitle: const Text(
                'An Feiertagen, im Urlaub und bei anderer Abwesenheit, '
                'z. B. 1,5 oder 2'),
            trailing: Text('× ${formatFactor(s.absenceWorkFactor)}',
                style: theme.textTheme.titleMedium),
            onTap: () async {
              final v = await _askFactor(context, s.absenceWorkFactor);
              if (v != null) {
                await state.updateSettings((x) => x.absenceWorkFactor = v);
              }
            },
          ),
          _Section('Feiertage'),
          ListTile(
            leading: const Icon(Icons.celebration_outlined),
            title: const Text('Bundesland'),
            subtitle: const Text(
                'Gesetzliche Feiertage zählen automatisch als Abwesenheit'),
            trailing: Text(s.federalState?.label ?? 'Keins',
                style: theme.textTheme.titleMedium),
            onTap: () async {
              final v = await _pickFederalState(context, s.federalState);
              if (v != null) {
                await state.updateSettings(
                    (x) => x.federalState = v.state);
              }
            },
          ),
          if (NotificationService.instance.supported) ...[
            _Section('Benachrichtigung'),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Start/Pause in der Benachrichtigung'),
              subtitle: const Text(
                  'Arbeitszeit direkt im Benachrichtigungsbereich steuern'),
              value: s.showNotification,
              onChanged: (v) =>
                  state.updateSettings((x) => x.showNotification = v),
            ),
          ],
          _Section('Daten'),
          const BackupTiles(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// Fragt den Faktor für Arbeit an Abwesenheitstagen ab.
Future<double?> _askFactor(BuildContext context, double initial) {
  final controller = TextEditingController(text: formatFactor(initial));
  String? error;
  return showDialog<double>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        void submit() {
          final v = parseFactor(controller.text);
          if (v == null) {
            setState(() => error = 'Zahl zwischen 0 und 10, z. B. 1,5');
            return;
          }
          Navigator.pop(c, v);
        }

        return AlertDialog(
          title: const Text('Faktor'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Wird an einem Feiertag, im Urlaub oder bei anderer '
                  'Abwesenheit gearbeitet, zählt jede Stunde so oft ins '
                  'Stundenkonto. 2 = doppelt, 1 = einfach.'),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  hintText: 'z. B. 1,5',
                  prefixText: '× ',
                  errorText: error,
                ),
                onSubmitted: (_) => submit(),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Abbrechen')),
            FilledButton(onPressed: submit, child: const Text('OK')),
          ],
        );
      },
    ),
  );
}

/// Ergebnis der Bundesland-Auswahl (`state == null` = keine Feiertage).
class _FederalStateChoice {
  const _FederalStateChoice(this.state);
  final FederalState? state;
}

Future<_FederalStateChoice?> _pickFederalState(
    BuildContext context, FederalState? current) {
  return showDialog<_FederalStateChoice>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('Bundesland'),
      children: [
        RadioGroup<FederalState?>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(c, _FederalStateChoice(v)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const RadioListTile<FederalState?>(
                value: null,
                title: Text('Keins (keine Feiertage)'),
              ),
              for (final fs in FederalState.values)
                RadioListTile<FederalState?>(
                  value: fs,
                  title: Text(fs.label),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Fragt einen Stundenwert ab (Format „8“, „7:30“, „7,5“). Ergebnis in Minuten.
Future<int?> _askHours(
  BuildContext context, {
  required String title,
  required String hint,
  required String initial,
  bool allowNegative = false,
}) {
  final controller = TextEditingController(text: initial);
  String? error;
  return showDialog<int>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        void submit() {
          final v = parseHoursToMinutes(controller.text);
          if (v == null || (!allowNegative && v < 0)) {
            setState(() => error = 'Ungültiger Wert');
            return;
          }
          Navigator.pop(c, v);
        }

        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(
                signed: allowNegative, decimal: true),
            decoration: InputDecoration(
              hintText: hint,
              suffixText: 'h',
              errorText: error,
            ),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Abbrechen')),
            FilledButton(onPressed: submit, child: const Text('OK')),
          ],
        );
      },
    ),
  );
}
