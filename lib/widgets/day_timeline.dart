import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../balance.dart';
import '../format.dart';
import '../models.dart';
import 'session_editor.dart';

/// Liste der Arbeitszeiten eines Tages inkl. Pausen dazwischen.
class DayTimeline extends StatelessWidget {
  const DayTimeline({super.key, required this.stats, required this.now});

  final DayStats stats;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final sessions = stats.sessions;
    for (var i = 0; i < sessions.length; i++) {
      final s = sessions[i];
      if (i > 0 && sessions[i - 1].end != null) {
        final gap = s.start.difference(sessions[i - 1].end!);
        if (gap > Duration.zero) {
          children.add(
            _PauseTile(before: sessions[i - 1], after: s, duration: gap),
          );
        }
      }
      children.add(_SessionTile(session: s, now: now));
    }
    if (children.isEmpty) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Keine Arbeitszeiten erfasst.'),
        ),
      );
    }
    return Column(children: children);
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.now});

  final WorkSession session;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final crossesMidnight = s.end != null && dayOf(s.end!) != dayOf(s.start);
    return ListTile(
      leading: Icon(
        s.isRunning ? Icons.timer : Icons.work_outline,
        color: s.isRunning ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(
        '${formatTime(s.start)} – ${s.isRunning ? 'läuft' : formatTime(s.end!)}${crossesMidnight ? ' (+1)' : ''}',
      ),
      subtitle: s.note == null ? null : Text(s.note!),
      trailing: Text(
        formatDuration(s.durationAt(now)),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      onTap: () => showSessionEditor(context, session: s.copy()),
    );
  }
}

/// Pause zwischen zwei Arbeitszeiten. Antippen bietet das Löschen an;
/// die umgebenden Abschnitte werden dann zusammengefasst.
class _PauseTile extends StatelessWidget {
  const _PauseTile({
    required this.before,
    required this.after,
    required this.duration,
  });

  final WorkSession before;
  final WorkSession after;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return InkWell(
      onTap: () => _delete(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.coffee_outlined,
              size: 18,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Pause ${formatDuration(duration)} '
                '(${formatTime(before.end!)} – ${formatTime(after.start)})',
                style: muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final state = context.read<AppState>();
    final end = after.isRunning ? 'läuft' : formatTime(after.end!);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Pause löschen?'),
        content: Text(
          'Die Pause von ${formatTime(before.end!)} bis '
          '${formatTime(after.start)} (${formatDuration(duration)}) wird '
          'gelöscht und als Arbeitszeit gezählt.\n\n'
          'Die Abschnitte werden zusammengefasst zu '
          '${formatTime(before.start)} – $end.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok == true) await state.deletePause(before.id, after.id);
  }
}
