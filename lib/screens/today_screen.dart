import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../format.dart';
import 'absences_screen.dart';
import '../widgets/day_timeline.dart';
import '../widgets/session_editor.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final calc = state.calc;
    final today = calc.statsFor(state.now);
    final balance = state.balance;
    final theme = Theme.of(context);
    final running = state.isRunning;
    final remaining = today.target - today.worked - today.credited;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AnTaTime'),
        actions: [
          IconButton(
            tooltip: 'Arbeitszeit nacherfassen',
            icon: const Icon(Icons.more_time),
            onPressed: () => showSessionEditor(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(formatDate(state.now), style: theme.textTheme.titleMedium),
          ),
          if (today.absence != null)
            Card(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              color: theme.colorScheme.tertiaryContainer,
              child: ListTile(
                leading: Icon(absenceIcon(today.absence!.type)),
                title: Text('Heute: ${today.absence!.label}'),
                subtitle: today.isWorkday
                    ? Text('Zählt als ${formatDuration(today.target)} h Arbeitszeit')
                    : null,
              ),
            ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              formatClock(today.worked),
              style: theme.textTheme.displayMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
          Center(
            child: Text(
              today.isWorkday
                  ? 'Soll ${formatDuration(today.target)} · ${remaining > Duration.zero ? 'noch ${formatDuration(remaining)}' : 'Überstunden ${formatDuration(-remaining)}'}'
                  : 'Freier Tag',
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (today.breaks > Duration.zero)
            Center(
              child: Text('Pausen ${formatDuration(today.breaks)}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
          const SizedBox(height: 24),
          Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  backgroundColor: running
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                onPressed: state.toggle,
                child: Icon(running ? Icons.pause : Icons.play_arrow, size: 64),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(running ? 'Pause' : 'Start',
                style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 24),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('Stundenkonto'),
              trailing: Text(
                formatSigned(balance),
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: balance.isNegative
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Heute erfasst', style: theme.textTheme.titleSmall),
          ),
          DayTimeline(stats: today, now: state.now),
        ],
      ),
    );
  }
}
