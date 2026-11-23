import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../balance.dart';
import '../format.dart';
import '../models.dart';
import '../widgets/day_bars.dart';
import '../widgets/session_editor.dart';
import 'day_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  void _shift(int delta) =>
      setState(() => _month = DateTime(_month.year, _month.month + delta));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final calc = state.calc;
    final today = dayOf(state.now);
    final theme = Theme.of(context);

    final lastOfMonth = DateTime(_month.year, _month.month + 1, 0);
    final last = lastOfMonth.isAfter(today) ? today : lastOfMonth;
    final days = <DayStats>[];
    for (var d = last;
        !d.isBefore(_month);
        d = DateTime(d.year, d.month, d.day - 1)) {
      days.add(calc.statsFor(d));
    }
    final monthWorked = days.fold(Duration.zero, (s, d) => s + d.worked);
    // Gemeinsamer Maßstab, damit die Tagesbalken vergleichbar sind.
    var barScale = Duration(minutes: state.data.settings.dailyTargetMinutes);
    for (final d in days) {
      for (final v in [d.worked, workTargetOf(d)]) {
        if (v > barScale) barScale = v;
      }
    }
    final monthDiff = calc.diffBetween(_month, lastOfMonth);
    final isCurrentMonth =
        _month.year == today.year && _month.month == today.month;

    return Scaffold(
      appBar: AppBar(title: const Text('Verlauf')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSessionEditor(context),
        icon: const Icon(Icons.more_time),
        label: const Text('Nacherfassen'),
      ),
      body: Column(
        children: [
          Row(
            children: [
              IconButton(
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left)),
              Expanded(
                child: Text(formatMonth(_month),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium),
              ),
              IconButton(
                  onPressed: isCurrentMonth ? null : () => _shift(1),
                  icon: const Icon(Icons.chevron_right)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              children: [
                Text('Gearbeitet: ${formatDuration(monthWorked)} h'),
                Text('Saldo: ${formatSigned(monthDiff)} h',
                    style: TextStyle(
                        color: monthDiff.isNegative
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary)),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: days.isEmpty
                ? const Center(child: Text('Keine Tage in diesem Monat.'))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: days.length,
                    itemBuilder: (context, i) => _DayRow(
                      stats: days[i],
                      counted: !days[i].day.isBefore(state.data.settings.startDate),
                      isToday: days[i].day == today,
                      barScale: barScale,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.stats,
    required this.counted,
    required this.isToday,
    required this.barScale,
  });

  final DayStats stats;
  final bool counted;
  final bool isToday;
  final Duration barScale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = stats;
    final diff = s.diff;
    final showDiff = counted && (!isToday || diff > Duration.zero) &&
        (s.isWorkday || s.worked > Duration.zero);

    String subtitle;
    if (s.absence != null) {
      subtitle = s.absence!.label;
      if (s.worked > Duration.zero) {
        subtitle += ' · ${formatDuration(s.worked)} h gearbeitet';
      }
    } else if (s.sessions.isEmpty) {
      subtitle = s.isWorkday ? 'Nichts erfasst' : 'Frei';
    } else {
      subtitle =
          '${formatTime(s.firstStart!)}–${s.lastEnd == null ? 'jetzt' : formatTime(s.lastEnd!)}'
          ' · ${formatDuration(s.worked)} h'
          '${s.breaks > Duration.zero ? ' · Pause ${formatDuration(s.breaks)}' : ''}';
    }
    if (s.absence == null && s.halfHoliday != null) {
      subtitle = '${s.halfHoliday!.label} (halber Feiertag) · $subtitle';
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: s.isWorkday
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        child: Text(weekdayShort[s.day.weekday - 1]),
      ),
      title: Text(formatDateShort(s.day) + (isToday ? ' (heute)' : '')),
      subtitle: s.worked > Duration.zero || workTargetOf(s) > Duration.zero
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(subtitle),
                const SizedBox(height: 6),
                DayProgressBar(stats: s, scale: barScale),
              ],
            )
          : Text(subtitle),
      trailing: showDiff
          ? Text(formatSigned(diff),
              style: theme.textTheme.titleMedium?.copyWith(
                  color: diff.isNegative
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary))
          : null,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DayScreen(day: s.day)),
      ),
    );
  }
}
