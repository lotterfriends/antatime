import 'package:flutter/material.dart';

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
    final theme = Theme.of(context);
    final children = <Widget>[];
    final sessions = stats.sessions;
    for (var i = 0; i < sessions.length; i++) {
      final s = sessions[i];
      if (i > 0 && sessions[i - 1].end != null) {
        final gap = s.start.difference(sessions[i - 1].end!);
        if (gap > Duration.zero) {
          children.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                Icon(Icons.coffee_outlined,
                    size: 18, color: theme.colorScheme.outline),
                const SizedBox(width: 12),
                Text('Pause ${formatDuration(gap)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ));
        }
      }
      children.add(_SessionTile(session: s, now: now));
    }
    if (children.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Keine Arbeitszeiten erfasst.'),
      ));
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
          '${formatTime(s.start)} – ${s.isRunning ? 'läuft' : formatTime(s.end!)}${crossesMidnight ? ' (+1)' : ''}'),
      subtitle: s.note == null ? null : Text(s.note!),
      trailing: Text(formatDuration(s.durationAt(now)),
          style: Theme.of(context).textTheme.titleMedium),
      onTap: () => showSessionEditor(context, session: s.copy()),
    );
  }
}
