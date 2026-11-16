import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../balance.dart';
import '../format.dart';
import '../models.dart';

/// Farbe für Überstunden – bewusst nicht aus dem (türkisen) Farbschema,
/// damit sie sich klar von normaler Arbeitszeit abhebt.
Color overtimeColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.orange.shade300
    : Colors.orange.shade800;

/// Soll, das an diesem Tag noch durch Arbeit zu erfüllen ist. An
/// Abwesenheitstagen ist das Soll durch die Gutschrift erfüllt, dort zählt
/// jede Arbeit als Überstunde.
Duration workTargetOf(DayStats s) {
  final t = s.target - s.credited;
  return t.isNegative ? Duration.zero : t;
}

/// Kleiner Balken: gearbeitete Zeit im Verhältnis zum Tagessoll.
/// Überstunden ragen in einer eigenen Farbe über das Soll hinaus.
///
/// [scale] ist die Dauer, die der vollen Breite entspricht – in einer Liste
/// für alle Zeilen gleich, damit die Balken vergleichbar sind.
class DayProgressBar extends StatelessWidget {
  const DayProgressBar({super.key, required this.stats, required this.scale});

  final DayStats stats;
  final Duration scale;

  static const double height = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = workTargetOf(stats);
    final worked = stats.worked;
    final scaleUs = math.max(
      scale.inMicroseconds,
      math.max(target.inMicroseconds, worked.inMicroseconds),
    );
    if (scaleUs <= 0) return const SizedBox(height: height);

    final normal = worked < target ? worked : target;
    final overtime = worked > target ? worked - target : Duration.zero;

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      double px(Duration d) => w * d.inMicroseconds / scaleUs;
      final radius = BorderRadius.circular(height / 2);
      // Kleine Lücke zwischen Soll und Überstunden als Markierung.
      const gap = 2.0;
      final normalW = px(normal);
      final overtimeW = px(overtime);
      return SizedBox(
        height: height,
        width: w,
        child: Stack(
          children: [
            // Spur bis zum Soll.
            if (target > Duration.zero)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: px(target),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: radius,
                  ),
                ),
              ),
            if (normalW > 0)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: normalW,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: radius,
                  ),
                ),
              ),
            if (overtimeW > 0)
              Positioned(
                left: normalW > 0 ? normalW + gap : 0,
                top: 0,
                bottom: 0,
                width: math.max(
                    overtimeW - (normalW > 0 ? gap : 0), height),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: overtimeColor(theme),
                    borderRadius: radius,
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}

enum _SegKind { work, overtime, pause }

class _Seg {
  _Seg(this.start, this.end, this.kind);
  final DateTime start;
  final DateTime end;
  final _SegKind kind;
}

/// Horizontaler Zeitstrahl eines Tages: Arbeit, Überstunden (Arbeit nach
/// Erreichen des Solls) und Pausen in unterschiedlichen Farben.
class DayTimeBar extends StatelessWidget {
  const DayTimeBar({super.key, required this.stats, required this.now});

  final DayStats stats;
  final DateTime now;

  List<_Seg> _segments() {
    final segs = <_Seg>[];
    var remaining = workTargetOf(stats);
    WorkSession? prev;
    for (final s in stats.sessions) {
      final end = s.end ?? now;
      if (!end.isAfter(s.start)) continue;
      if (prev != null) {
        final prevEnd = prev.end ?? now;
        if (s.start.isAfter(prevEnd)) {
          segs.add(_Seg(prevEnd, s.start, _SegKind.pause));
        }
      }
      final d = end.difference(s.start);
      if (remaining >= d) {
        segs.add(_Seg(s.start, end, _SegKind.work));
        remaining -= d;
      } else {
        final split = s.start.add(remaining);
        if (remaining > Duration.zero) {
          segs.add(_Seg(s.start, split, _SegKind.work));
        }
        segs.add(_Seg(split, end, _SegKind.overtime));
        remaining = Duration.zero;
      }
      prev = s;
    }
    return segs;
  }

  @override
  Widget build(BuildContext context) {
    final segs = _segments();
    if (segs.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    // Auf volle Stunden gerundeter Bereich.
    final first = segs.first.start;
    final last = segs.last.end;
    final from = DateTime(first.year, first.month, first.day, first.hour);
    var to = DateTime(last.year, last.month, last.day, last.hour);
    if (to.isBefore(last)) to = to.add(const Duration(hours: 1));
    if (!to.isAfter(from)) to = from.add(const Duration(hours: 1));
    final rawHours = to.difference(from).inHours;
    final step = rawHours <= 10 ? 1 : (rawHours <= 20 ? 2 : 3);
    // Ende auf ein Vielfaches der Schrittweite verlängern, damit die letzte
    // Beschriftung genau am rechten Rand steht.
    final hours = (rawHours + step - 1) ~/ step * step;
    to = from.add(Duration(hours: hours));
    final spanUs = to.difference(from).inMicroseconds;

    Color colorOf(_SegKind k) => switch (k) {
          _SegKind.work => theme.colorScheme.primary,
          _SegKind.overtime => overtimeColor(theme),
          _SegKind.pause => theme.colorScheme.outline,
        };
    String labelOf(_SegKind k) => switch (k) {
          _SegKind.work => 'Arbeit',
          _SegKind.overtime => 'Überstunden',
          _SegKind.pause => 'Pause',
        };

    final hasWork = segs.any((s) => s.kind == _SegKind.work);
    final hasOvertime = segs.any((s) => s.kind == _SegKind.overtime);
    final hasPause = segs.any((s) => s.kind == _SegKind.pause);
    final labelStyle = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        double x(DateTime t) =>
            w * t.difference(from).inMicroseconds / spanUs;

        const barH = 8.0;
        const pauseH = 2.0;
        const pill = Radius.circular(barH / 2);
        final labels = <Widget>[];
        for (var h = 0; h <= hours; h += step) {
          final t = from.add(Duration(hours: h));
          final px = x(t);
          const labelW = 40.0;
          final left = (px - labelW / 2).clamp(0.0, w - labelW);
          final align = h == 0
              ? TextAlign.left
              : (h == hours ? TextAlign.right : TextAlign.center);
          labels.add(Positioned(
            left: align == TextAlign.left
                ? 0
                : (align == TextAlign.right ? w - labelW : left),
            top: barH + 4,
            width: labelW,
            child: Text('${t.hour}', textAlign: align, style: labelStyle),
          ));
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: barH + 4 + 14,
              width: w,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: barH,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: const BorderRadius.all(pill),
                      ),
                    ),
                  ),
                  for (var i = 0; i < segs.length; i++)
                    _segment(
                      segs: segs,
                      i: i,
                      x: x,
                      barH: barH,
                      pauseH: pauseH,
                      pill: pill,
                      color: colorOf(segs[i].kind),
                      label: labelOf(segs[i].kind),
                    ),
                  ...labels,
                ],
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                if (hasWork)
                  _Legend(color: colorOf(_SegKind.work), label: 'Arbeit'),
                if (hasOvertime)
                  _Legend(
                      color: colorOf(_SegKind.overtime), label: 'Überstunden'),
                if (hasPause)
                  _Legend(color: colorOf(_SegKind.pause), label: 'Pause'),
              ],
            ),
          ],
        );
      }),
    );
  }
}

/// Ein Abschnitt des Zeitstrahls. Arbeitsabschnitte sind Pillen; geht eine
/// Arbeitszeit nahtlos in Überstunden über, bleibt die Naht eckig, damit
/// beides als ein Stück erscheint. Pausen sind eine dünne Linie.
Widget _segment({
  required List<_Seg> segs,
  required int i,
  required double Function(DateTime) x,
  required double barH,
  required double pauseH,
  required Radius pill,
  required Color color,
  required String label,
}) {
  final s = segs[i];
  final isPause = s.kind == _SegKind.pause;
  bool joined(_Seg a, _Seg b) =>
      a.kind != _SegKind.pause &&
      b.kind != _SegKind.pause &&
      a.end == b.start;
  final roundLeft = isPause || i == 0 || !joined(segs[i - 1], s);
  final roundRight =
      isPause || i == segs.length - 1 || !joined(s, segs[i + 1]);
  final h = isPause ? pauseH : barH;
  final r = isPause ? Radius.circular(pauseH / 2) : pill;
  // Pausen mit etwas Abstand zu den Arbeitsabschnitten.
  final inset = isPause ? 3.0 : 0.0;
  final left = x(s.start) + inset;
  final width = math.max(x(s.end) - x(s.start) - 2 * inset, 1.0);
  return Positioned(
    left: left,
    top: (barH - h) / 2,
    height: h,
    width: width,
    child: Tooltip(
      message: '$label ${formatTime(s.start)} – ${formatTime(s.end)} '
          '(${formatDuration(s.end.difference(s.start))})',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.horizontal(
            left: roundLeft ? r : Radius.zero,
            right: roundRight ? r : Radius.zero,
          ),
        ),
      ),
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
