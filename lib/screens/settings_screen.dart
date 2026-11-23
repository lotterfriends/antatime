import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../click_cursor.dart';
import '../desktop/autostart.dart';
import '../desktop/desktop_notifications.dart';
import '../format.dart';
import '../models.dart';
import '../notification_service.dart';
import '../tray_icon_style.dart';
import '../tray_service.dart';
import '../widgets/autostart_tile.dart';
import '../widgets/backup_tiles.dart';
import '../widgets/sync_tiles.dart';

/// Speichert eine Einstellung. Gilt eine Änderung am Stundenkonto erst ab
/// heute (siehe [AppState.updateSettings]), lässt sie sich per Snackbar auch
/// rückwirkend anwenden.
Future<void> _updateSettings(
    BuildContext context, void Function(Settings s) change) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  if (!await state.updateSettings(change)) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: const Text(
          'Gilt ab heute – das Stundenkonto bis gestern bleibt unverändert.'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: 'Rückwirkend',
        onPressed: state.applySettingsRetroactively,
      ),
    ));
}

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
                if (!context.mounted) return;
                await _updateSettings(context, (x) => x.startBalanceMinutes = v);
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
              if (d != null && context.mounted) await _updateSettings(context, (x) => x.startDate = d);
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
                if (!context.mounted) return;
                await _updateSettings(context, (x) {
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
                if (!context.mounted) return;
                await _updateSettings(context, (x) {
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
                    mouseCursor: clickCursor,
                    label: Text(weekdayShort[wd - 1]),
                    selected: s.workdays.contains(wd),
                    onSelected: (sel) => _updateSettings(context, (x) {
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
                if (!context.mounted) return;
                await _updateSettings(context, (x) => x.absenceWorkFactor = v);
              }
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.nightlight_outlined),
            title: const Text('Faktor für Arbeit am Abend'),
            subtitle: Text(s.lateWorkMinutes == null
                ? 'Arbeit ab einer bestimmten Uhrzeit zählt mehrfach'
                : 'Arbeit ab ${formatMinutesOfDay(s.lateWorkMinutes!)} Uhr '
                    'zählt × ${formatFactor(s.lateWorkFactor)}'),
            value: s.lateWorkMinutes != null,
            onChanged: (v) async {
              if (!v) {
                await _updateSettings(context, (x) => x.lateWorkMinutes = null);
                return;
              }
              final m = await _pickTime(context, 20 * 60, 'Faktor gilt ab');
              if (m == null || !context.mounted) return;
              final f = await _askFactor(
                  context, s.lateWorkFactor == 1 ? 1.5 : s.lateWorkFactor,
                  lateWork: true);
              if (f == null) return;
              if (!context.mounted) return;
              await _updateSettings(context, (x) {
                x.lateWorkMinutes = m;
                x.lateWorkFactor = f;
              });
            },
          ),
          if (s.lateWorkMinutes != null) ...[
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Ab Uhrzeit'),
              trailing: Text('${formatMinutesOfDay(s.lateWorkMinutes!)} Uhr',
                  style: theme.textTheme.titleMedium),
              onTap: () async {
                final m = await _pickTime(
                    context, s.lateWorkMinutes!, 'Faktor gilt ab');
                if (m != null) {
                  if (!context.mounted) return;
                  await _updateSettings(context, (x) => x.lateWorkMinutes = m);
                }
              },
            ),
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Faktor'),
              trailing: Text('× ${formatFactor(s.lateWorkFactor)}',
                  style: theme.textTheme.titleMedium),
              onTap: () async {
                final v = await _askFactor(context, s.lateWorkFactor,
                    lateWork: true);
                if (v != null) {
                  if (!context.mounted) return;
                  await _updateSettings(context, (x) => x.lateWorkFactor = v);
                }
              },
            ),
          ],
          if (s.absenceWorkFactor > 1 &&
              s.lateWorkMinutes != null &&
              s.lateWorkFactor > 1)
            SwitchListTile(
              secondary: const Icon(Icons.add_circle_outline),
              title: const Text('Faktoren addieren'),
              subtitle: Text(_stackExample(s)),
              value: s.stackWorkFactors,
              onChanged: (v) =>
                  _updateSettings(context, (x) => x.stackWorkFactors = v),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Faktoren gelten nur für die Arbeitszeit, nicht für Pausen.',
              style: theme.textTheme.bodySmall,
            ),
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
                if (!context.mounted) return;
                await _updateSettings(context, 
                    (x) => x.federalState = v.state);
              }
            },
          ),
          SwitchListTile(
            secondary: Icon(s.halfHolidays
                ? Icons.star_half_outlined
                : Icons.star_outlined),
            title: const Text('Heiligabend und Silvester ganz frei'),
            subtitle: Text(s.halfHolidays
                ? '24.12. und 31.12. sind halbe Feiertage: halbes Soll, '
                    'Urlaub zählt dort als halber Tag'
                : 'Der Arbeitgeber schenkt die zweite Tageshälfte: '
                    '24.12. und 31.12. sind ganz frei, kein Urlaub nötig'),
            value: !s.halfHolidays,
            onChanged: (v) => _updateSettings(context, (x) => x.halfHolidays = !v),
          ),
          if (NotificationService.instance.supported ||
              DesktopNotifications.supported)
            _Section('Benachrichtigung'),
          if (NotificationService.instance.supported) ...[
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Start/Pause in der Benachrichtigung'),
              subtitle: const Text(
                  'Arbeitszeit direkt im Benachrichtigungsbereich steuern'),
              value: s.showNotification,
              onChanged: (v) =>
                  _updateSettings(context, (x) => x.showNotification = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.alarm),
              title: const Text('Erinnerung zum Start'),
              subtitle: const Text('An Arbeitstagen erinnern, falls die '
                  'Zeiterfassung noch nicht gestartet wurde (nicht an '
                  'Feiertagen und bei Abwesenheit)'),
              value: s.reminderMinutes != null,
              onChanged: (v) async {
                if (!v) {
                  await _updateSettings(context, (x) => x.reminderMinutes = null);
                  return;
                }
                final m = await _pickReminderTime(context, 9 * 60);
                if (m != null) {
                  if (!context.mounted) return;
                  await _updateSettings(context, (x) => x.reminderMinutes = m);
                }
              },
            ),
            if (s.reminderMinutes != null)
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Uhrzeit der Erinnerung'),
                trailing: Text('${formatMinutesOfDay(s.reminderMinutes!)} Uhr',
                    style: theme.textTheme.titleMedium),
                onTap: () async {
                  final m =
                      await _pickReminderTime(context, s.reminderMinutes!);
                  if (m != null) {
                    if (!context.mounted) return;
                    await _updateSettings(context, (x) => x.reminderMinutes = m);
                  }
                },
              ),
          ],
          if (NotificationService.instance.supported ||
              DesktopNotifications.supported)
            SwitchListTile(
              secondary: const Icon(Icons.flag_outlined),
              title: const Text('Erinnerung bei Erreichen der Tagesstunden'),
              subtitle: Text('Benachrichtigen, sobald an Arbeitstagen '
                  '${formatDuration(Duration(minutes: s.dailyTargetMinutes))} h '
                  'gearbeitet sind (nicht an Feiertagen und bei Abwesenheit)'),
              value: s.targetReminder,
              onChanged: (v) async {
                await _updateSettings(context, (x) => x.targetReminder = v);
                if (v) await DesktopNotifications.instance.requestPermission();
              },
            ),
          if (TrayService.supported) ...[
            _Section('Infobereich'),
            SwitchListTile(
              secondary: const Icon(Icons.schedule_outlined),
              title: const Text('Symbol im Infobereich (Tray)'),
              subtitle: const Text('Start/Pause und Feierabend über das '
                  'Symbol; Schließen des Fensters minimiert in den '
                  'Infobereich'),
              value: s.showNotification,
              onChanged: (v) =>
                  _updateSettings(context, (x) => x.showNotification = v),
            ),
            if (s.showNotification && TrayService.iconStyleSupported)
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Darstellung des Symbols'),
                subtitle: const Text('Einfarbig passt besser zu hellen '
                    'bzw. dunklen Leisten'),
                trailing: _TrayIconPreview(state.trayIconStyle),
                onTap: () async {
                  final v = await _pickTrayIconStyle(
                      context, state.trayIconStyle);
                  if (v != null) await state.setTrayIconStyle(v);
                },
              ),
          ],
          if (Autostart.instance.supported) ...[
            _Section('Programmstart'),
            const AutostartTile(),
          ],
          _Section('Synchronisation'),
          const SyncTiles(),
          _Section('Daten'),
          const BackupTiles(),
          const _VersionInfo(),
        ],
      ),
    );
  }
}

/// Versionsnummer der App (aus der pubspec.yaml) am Ende der Einstellungen.
class _VersionInfo extends StatefulWidget {
  const _VersionInfo();

  @override
  State<_VersionInfo> createState() => _VersionInfoState();
}

class _VersionInfoState extends State<_VersionInfo> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        final text = info == null
            ? ''
            : 'AnTaTime ${info.version}'
                '${info.buildNumber.isEmpty ? '' : ' (${info.buildNumber})'}';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        );
      },
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

/// Erklärt am Beispiel einer Abendstunde an einem Feiertag, wie die beiden
/// Faktoren zusammenwirken.
String _stackExample(Settings s) {
  final a = s.absenceWorkFactor, l = s.lateWorkFactor;
  final combined = s.stackWorkFactors ? a + l - 1 : (a > l ? a : l);
  return 'Abends an Abwesenheitstagen: '
      '${s.stackWorkFactors ? 'Zuschläge addieren sich' : 'nur der höhere Faktor zählt'}'
      ' – eine Stunde zählt ${formatFactor(combined)} h';
}

/// Uhrzeit für die Start-Erinnerung wählen (Minuten nach Mitternacht).
Future<int?> _pickReminderTime(BuildContext context, int initial) =>
    _pickTime(context, initial, 'Erinnerung um');

/// Uhrzeit wählen (Minuten nach Mitternacht).
Future<int?> _pickTime(BuildContext context, int initial, String help) async {
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
    helpText: help,
  );
  return t == null ? null : t.hour * 60 + t.minute;
}

/// Fragt den Faktor für Arbeit an Abwesenheitstagen bzw. – mit
/// [lateWork] – für Arbeit am Abend ab.
Future<double?> _askFactor(BuildContext context, double initial,
    {bool lateWork = false}) {
  String? error;
  return showDialog<double>(
    context: context,
    builder: (c) => _WithController(
      initial: formatFactor(initial),
      builder: (controller) => StatefulBuilder(
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
              Text(lateWork
                  ? 'Jede Stunde Arbeit ab der eingestellten Uhrzeit zählt '
                      'so oft ins Stundenkonto (Pausen nicht). '
                      '2 = doppelt, 1 = einfach.'
                  : 'Wird an einem Feiertag, im Urlaub oder bei anderer '
                      'Abwesenheit gearbeitet, zählt jede Stunde so oft ins '
                      'Stundenkonto (Pausen nicht). 2 = doppelt, 1 = einfach.'),
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
    ),
  );
}

Future<TrayIconStyle?> _pickTrayIconStyle(
    BuildContext context, TrayIconStyle current) {
  return showDialog<TrayIconStyle>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('Symbol im Infobereich'),
      children: [
        RadioGroup<TrayIconStyle>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(c, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final style in TrayIconStyle.values)
                RadioListTile<TrayIconStyle>(
                  value: style,
                  title: Align(
                    alignment: Alignment.centerLeft,
                    child: _TrayIconPreview(style),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Vorschau des Tray-Symbols in [style] auf einer passenden Leiste
/// (einfarbig hell auf dunkel, einfarbig dunkel auf hell), laufend und
/// pausiert.
class _TrayIconPreview extends StatelessWidget {
  const _TrayIconPreview(this.style);

  final TrayIconStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = switch (style) {
      TrayIconStyle.color => scheme.surfaceContainerHighest,
      TrayIconStyle.light => const Color(0xFF2B2B2B),
      TrayIconStyle.dark => const Color(0xFFE8E8E8),
    };
    Widget icon(String name) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Image.asset('assets/tray/$name${style.suffix}.png',
              width: 22, height: 22, filterQuality: FilterQuality.medium),
        );
    return Semantics(
      label: style.label,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [icon('running'), icon('paused')],
          ),
        ),
      ),
    );
  }
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
  String? error;
  return showDialog<int>(
    context: context,
    builder: (c) => _WithController(
      initial: initial,
      builder: (controller) => StatefulBuilder(
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
    ),
  );
}

/// Hält den [TextEditingController] eines Dialogs und gibt ihn frei, wenn
/// der Dialog wirklich geschlossen ist – nicht schon, wenn `showDialog`
/// zurückkehrt (während der Schließ-Animation hängt das Textfeld noch daran).
class _WithController extends StatefulWidget {
  const _WithController({required this.initial, required this.builder});

  final String initial;
  final Widget Function(TextEditingController controller) builder;

  @override
  State<_WithController> createState() => _WithControllerState();
}

class _WithControllerState extends State<_WithController> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}
