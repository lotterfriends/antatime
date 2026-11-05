import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../format.dart';
import '../widgets/day_timeline.dart';
import '../widgets/session_editor.dart';
import 'absences_screen.dart';

class DayScreen extends StatelessWidget {
  const DayScreen({super.key, required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final stats = state.calc.statsFor(day);
    final theme = Theme.of(context);

    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label),
              Text(value,
                  style: theme.textTheme.titleMedium?.copyWith(color: color)),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(formatDate(day))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSessionEditor(context, day: day),
        icon: const Icon(Icons.add),
        label: const Text('Arbeitszeit'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  row('Gearbeitet', formatDuration(stats.worked)),
                  if (stats.bonus != Duration.zero)
                    row('Zuschlag (× ${formatFactor(stats.workFactor)})',
                        formatDuration(stats.bonus)),
                  row('Pausen', formatDuration(stats.breaks)),
                  row('Soll', formatDuration(stats.target)),
                  if (stats.credited > Duration.zero)
                    row('Gutschrift (${stats.absence!.label})',
                        formatDuration(stats.credited)),
                  const Divider(),
                  row('Differenz', formatSigned(stats.diff),
                      color: stats.diff.isNegative
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary),
                ],
              ),
            ),
          ),
          if (stats.absence != null)
            ListTile(
              leading: Icon(absenceIcon(stats.absence!.type)),
              title: Text(stats.absence!.label),
              subtitle: Text(stats.absence!.isHoliday
                  ? 'Gesetzlicher Feiertag'
                  : '${formatDateShort(stats.absence!.from)} – ${formatDateShort(stats.absence!.to)}'),
              onTap: stats.absence!.isHoliday
                  ? null
                  : () => showAbsenceEditor(context, absence: stats.absence),
            )
          else
            ListTile(
              leading: const Icon(Icons.event_available),
              title: const Text('Abwesenheit eintragen'),
              onTap: () => showAbsenceEditor(context, day: day),
            ),
          const Divider(),
          DayTimeline(stats: stats, now: state.now),
        ],
      ),
    );
  }
}
