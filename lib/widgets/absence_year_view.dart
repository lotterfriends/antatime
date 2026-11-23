import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../balance.dart';
import '../click_cursor.dart';
import '../format.dart';
import '../models.dart';
import '../screens/absences_screen.dart';

/// Hintergrundfarbe eines Tages je Abwesenheitsart.
Color absenceColor(ColorScheme c, AbsenceType t) => switch (t) {
  AbsenceType.vacation => c.tertiaryContainer,
  AbsenceType.sick => c.errorContainer,
  AbsenceType.other => c.secondaryContainer,
  AbsenceType.holiday => c.primaryContainer,
};

Color _absenceOnColor(ColorScheme c, AbsenceType t) => switch (t) {
  AbsenceType.vacation => c.onTertiaryContainer,
  AbsenceType.sick => c.onErrorContainer,
  AbsenceType.other => c.onSecondaryContainer,
  AbsenceType.holiday => c.onPrimaryContainer,
};

/// Jahreskalender mit allen Monaten und eingetragenen Abwesenheiten.
///
/// Ein Klick auf einen Tag trägt eine Abwesenheit ein (bzw. öffnet die
/// vorhandene), mit gedrückter Maustaste – auf Touch-Geräten nach langem
/// Drücken – lässt sich ein Zeitraum markieren, auch über Monate hinweg.
class AbsenceYearView extends StatefulWidget {
  const AbsenceYearView({super.key});

  @override
  State<AbsenceYearView> createState() => _AbsenceYearViewState();
}

class _AbsenceYearViewState extends State<AbsenceYearView> {
  late int _year;
  DateTime? _anchor;
  DateTime? _current;

  /// Monatskarte des aktuellen Monats (zum Hinscrollen beim Öffnen).
  final _currentMonthKey = GlobalKey();

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Anderes Jahr anzeigen, beginnend beim Januar.
  void _shiftYear(int delta) {
    setState(() => _year += delta);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  static const _touchDevices = {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  void initState() {
    super.initState();
    _year = DateTime.now().year;
    // Beim Öffnen zum aktuellen Monat scrollen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentMonthKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx);
    });
  }

  bool get _selecting => _anchor != null;

  DateTime? get _selFrom =>
      _selecting ? (_anchor!.isBefore(_current!) ? _anchor : _current) : null;

  DateTime? get _selTo =>
      _selecting ? (_anchor!.isBefore(_current!) ? _current : _anchor) : null;

  /// Der Tag unter [global], falls dort ein Tag des Kalenders liegt.
  DateTime? _dayAt(Offset global) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is _DayTag) {
        return (target.metaData as _DayTag).day;
      }
    }
    return null;
  }

  void _start(Offset global) {
    final d = _dayAt(global);
    if (d == null) return;
    setState(() => _anchor = _current = d);
  }

  void _update(Offset global) {
    if (!_selecting) return;
    final d = _dayAt(global);
    if (d != null && d != _current) setState(() => _current = d);
  }

  void _cancel() {
    if (_selecting) setState(() => _anchor = _current = null);
  }

  Future<void> _finish() async {
    if (!_selecting) return;
    final from = _selFrom!;
    final to = _selTo!;
    final state = context.read<AppState>();
    Absence? existing;
    if (from == to) {
      for (final a in state.data.absences) {
        if (a.covers(from)) {
          existing = a;
          break;
        }
      }
    }
    if (existing != null) {
      await showAbsenceEditor(context, absence: existing);
    } else {
      await showAbsenceEditor(
        context,
        range: DateTimeRange(start: from, end: to),
      );
    }
    if (mounted) _cancel();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final calc = state.calc;
    final theme = Theme.of(context);
    final today = dayOf(state.now);

    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Vorheriges Jahr',
              onPressed: () => _shiftYear(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '$_year',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Nächstes Jahr',
              onPressed: () => _shiftYear(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        _Summary(year: _year, calc: calc),
        const Divider(),
        Expanded(
          child: Listener(
            // Maus: Klicken bzw. Ziehen markiert sofort.
            onPointerDown: (e) {
              if (e.kind == PointerDeviceKind.mouse &&
                  e.buttons == kPrimaryMouseButton) {
                _start(e.position);
              }
            },
            onPointerMove: (e) {
              if (e.kind == PointerDeviceKind.mouse) _update(e.position);
            },
            onPointerUp: (e) {
              if (e.kind == PointerDeviceKind.mouse) _finish();
            },
            onPointerCancel: (e) {
              if (e.kind == PointerDeviceKind.mouse) _cancel();
            },
            // Touch: Tippen = ein Tag, lange drücken und ziehen = Zeitraum
            // (normales Wischen scrollt weiterhin).
            child: GestureDetector(
              supportedDevices: _touchDevices,
              onTapUp: (d) {
                _start(d.globalPosition);
                _finish();
              },
              onLongPressStart: (d) => _start(d.globalPosition),
              onLongPressMoveUpdate: (d) => _update(d.globalPosition),
              onLongPressEnd: (_) => _finish(),
              onLongPressCancel: _cancel,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const pad = 12.0;
                  const gap = 12.0;
                  final width = constraints.maxWidth - 2 * pad;
                  final cols = (width / 250).floor().clamp(1, 4);
                  final monthWidth = (width - gap * (cols - 1)) / cols;
                  return SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(pad, 0, pad, 88),
                    child: Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (var m = 1; m <= 12; m++)
                          SizedBox(
                            key: _year == today.year && m == today.month
                                ? _currentMonthKey
                                : null,
                            width: monthWidth,
                            child: _MonthGrid(
                              month: DateTime(_year, m),
                              calc: calc,
                              today: today,
                              selFrom: _selFrom,
                              selTo: _selTo,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Runde Tagesform: Kreis in der Mitte, optional mit Band zum linken
/// und/oder rechten Nachbartag.
class _DayShape extends StatelessWidget {
  const _DayShape({
    this.color,
    this.border,
    this.left = false,
    this.right = false,
    this.circle = true,
    this.half = false,
  });

  final Color? color;
  final BoxBorder? border;
  final bool left;
  final bool right;
  final bool circle;

  /// Nur die rechte Hälfte des Kreises (halber Feiertag = Nachmittag frei).
  final bool half;

  static const _inset = 1.5;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (left || right)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: _inset),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: left ? ColoredBox(color: color!) : const SizedBox(),
              ),
              Expanded(
                child: right ? ColoredBox(color: color!) : const SizedBox(),
              ),
            ],
          ),
        ),
      if (circle)
        Center(
          child: AspectRatio(
            aspectRatio: 1,
            child: Padding(
              padding: const EdgeInsets.all(_inset),
              child: ClipRect(
                clipper: half ? const _RightHalf() : null,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    border: border,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _RightHalf extends CustomClipper<Rect> {
  const _RightHalf();

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(size.width / 2, 0, size.width, size.height);

  @override
  bool shouldReclip(_RightHalf oldClipper) => false;
}

/// Markiert ein Tagesfeld für die Treffer-Ermittlung beim Ziehen.
class _DayTag {
  const _DayTag(this.day);
  final DateTime day;
}

/// Verbrauchte Arbeitstage je Abwesenheitsart im Jahr und Legende.
class _Summary extends StatelessWidget {
  const _Summary({required this.year, required this.calc});

  final int year;
  final BalanceCalculator calc;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final days = _typeDays(calc, year);
    // Heiligabend und Silvester sind immer (halbe oder ganze) Feiertage.
    final types = [...AbsenceType.editable, AbsenceType.holiday];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 4,
        runSpacing: 0,
        alignment: WrapAlignment.center,
        children: [
          for (final t in types)
            InkWell(
              mouseCursor: clickCursor,
              borderRadius: BorderRadius.circular(8),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => _TypeDaysDialog(
                  type: t,
                  year: year,
                  days: days[t]!,
                  // Tage, die einen Zeitraum nicht unterbrechen: freie
                  // Tage und ganze Feiertage.
                  isGap: (d) =>
                      !calc.settingsFor(d).workdays.contains(d.weekday) ||
                      calc.holidayFor(d) != null,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: absenceColor(c, t),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_shortLabel(t)}: '
                      '${formatHoursNumber(_sum(days[t]!))}',
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _shortLabel(AbsenceType t) =>
    t == AbsenceType.other ? 'Andere' : t.label;

/// Ein Arbeitstag mit Abwesenheit einer Art.
class _TypeDay {
  const _TypeDay(this.day, {this.half = false, this.name});

  final DateTime day;

  /// Zählt nur halb (halber Feiertag).
  final bool half;

  /// Name des Feiertags.
  final String? name;
}

double _sum(List<_TypeDay> days) =>
    days.fold(0.0, (n, d) => n + (d.half ? 0.5 : 1));

/// Arbeitstage des Jahres je Abwesenheitsart (wie in der Legende gezählt).
Map<AbsenceType, List<_TypeDay>> _typeDays(BalanceCalculator calc, int year) {
  final result = {for (final t in AbsenceType.values) t: <_TypeDay>[]};
  for (
    var d = DateTime(year, 1, 1);
    d.year == year;
    d = DateTime(d.year, d.month, d.day + 1)
  ) {
    if (!calc.settingsFor(d).workdays.contains(d.weekday)) continue;
    final a = calc.absenceFor(d);
    // Halber Feiertag: je ein halber Tag Feiertag und ggf. Abwesenheit.
    final half = calc.halfHolidayFor(d);
    if (half != null) {
      result[AbsenceType.holiday]!.add(
        _TypeDay(d, half: true, name: half.label),
      );
    }
    if (a != null) {
      result[a.type]!.add(
        _TypeDay(d, half: half != null, name: a.isHoliday ? a.label : null),
      );
    }
  }
  return result;
}

/// Alle Tage einer Abwesenheitsart im Jahr, nach Monaten gruppiert und
/// in die Zwischenablage kopierbar.
class _TypeDaysDialog extends StatefulWidget {
  const _TypeDaysDialog({
    required this.type,
    required this.year,
    required this.days,
    required this.isGap,
  });

  final AbsenceType type;
  final int year;
  final List<_TypeDay> days;

  /// Liegt dieser Tag zwischen zwei Einträgen, gelten sie trotzdem als
  /// direkt aufeinanderfolgend (z. B. Wochenende).
  final bool Function(DateTime day) isGap;

  @override
  State<_TypeDaysDialog> createState() => _TypeDaysDialogState();
}

class _TypeDaysDialogState extends State<_TypeDaysDialog> {
  bool _copied = false;

  String get _title => '${_shortLabel(widget.type)} ${widget.year}';

  String _line(_TypeDay d) =>
      '${formatDate(d.day)}'
      '${d.name != null ? ' – ${d.name}' : ''}'
      '${d.half ? ' (halber Tag)' : ''}';

  /// Folgt [b] direkt auf [a] (nur freie Tage/Feiertage dazwischen)?
  bool _adjacent(DateTime a, DateTime b) {
    for (
      var d = DateTime(a.year, a.month, a.day + 1);
      d.isBefore(b);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      if (!widget.isGap(d)) return false;
    }
    return true;
  }

  /// Zeilen eines Monats: aufeinanderfolgende ganze Tage als Zeitraum,
  /// z. B. „06.01.2025 – 10.01.2025 (5 Tage)“. Feiertage (mit Namen) und
  /// halbe Tage stehen einzeln.
  List<String> _lines(List<_TypeDay> days) {
    bool plain(_TypeDay d) => d.name == null && !d.half;
    final out = <String>[];
    var i = 0;
    while (i < days.length) {
      var j = i;
      if (plain(days[i])) {
        while (j + 1 < days.length &&
            plain(days[j + 1]) &&
            _adjacent(days[j].day, days[j + 1].day)) {
          j++;
        }
      }
      out.add(
        j == i
            ? _line(days[i])
            : '${formatDateShort(days[i].day)} – '
                  '${formatDateShort(days[j].day)} (${j - i + 1} Tage)',
      );
      i = j + 1;
    }
    return out;
  }

  Map<int, List<_TypeDay>> get _byMonth {
    final out = <int, List<_TypeDay>>{};
    for (final d in widget.days) {
      out.putIfAbsent(d.day.month, () => []).add(d);
    }
    return out;
  }

  String _monthHeader(int month, int count) =>
      '${DateFormat.MMMM('de_DE').format(DateTime(widget.year, month))} '
      '($count)';

  String get _text {
    final b = StringBuffer('$_title: ${formatWorkdays(_sum(widget.days))}\n');
    _byMonth.forEach((m, days) {
      b.writeln();
      b.writeln(_monthHeader(m, days.length));
      for (final line in _lines(days)) {
        b.writeln(line);
      }
    });
    return b.toString();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Flache Liste aus Monatsüberschriften und Tagen, damit auch sehr
    // viele Einträge nur so weit aufgebaut werden, wie sie sichtbar sind.
    final items = <({bool header, String text})>[];
    _byMonth.forEach((m, days) {
      items.add((header: true, text: _monthHeader(m, days.length)));
      for (final line in _lines(days)) {
        items.add((header: false, text: line));
      }
    });
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: const CloseButton(),
          title: Text(_title),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: widget.days.isEmpty ? null : _copy,
                icon: Icon(_copied ? Icons.check : Icons.copy),
                label: Text(_copied ? 'Kopiert' : 'Kopieren'),
              ),
            ),
          ],
        ),
        body: widget.days.isEmpty
            ? Center(child: Text('Keine Einträge in ${widget.year}.'))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: items.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return ListTile(
                          title: Text(
                            formatWorkdays(_sum(widget.days)),
                            style: theme.textTheme.titleMedium,
                          ),
                        );
                      }
                      final item = items[i - 1];
                      if (item.header) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text(
                            item.text,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Text(item.text),
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.calc,
    required this.today,
    required this.selFrom,
    required this.selTo,
  });

  final DateTime month;
  final BalanceCalculator calc;
  final DateTime today;
  final DateTime? selFrom;
  final DateTime? selTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final lead = month.weekday - 1; // Montag zuerst
    // Immer sechs Wochen, damit alle Monate gleich hoch sind.
    const cells = 42;

    Widget dayCell(int i) {
      final dayNum = i - lead + 1;
      if (dayNum < 1 || dayNum > daysInMonth) return const SizedBox.shrink();
      final day = DateTime(month.year, month.month, dayNum);
      final absence = calc.absenceFor(day);
      final selected =
          selFrom != null && !day.isBefore(selFrom!) && !day.isAfter(selTo!);
      final freeDay = !calc.settingsFor(day).workdays.contains(day.weekday);

      // Wie im Datumsauswahl-Dialog: einzelne Tage als Kreis, aufeinander
      // folgende Tage einer Woche als durchgehendes Band mit runden Enden.
      final first = day.weekday == DateTime.monday || dayNum == 1;
      final last = day.weekday == DateTime.sunday || dayNum == daysInMonth;
      final prev = DateTime(day.year, day.month, day.day - 1);
      final next = DateTime(day.year, day.month, day.day + 1);
      bool inSel(DateTime d) =>
          selFrom != null && !d.isBefore(selFrom!) && !d.isAfter(selTo!);

      Color fg = freeDay
          ? c.onSurfaceVariant.withValues(alpha: 0.6)
          : c.onSurface;
      final layers = <Widget>[];
      if (absence != null) {
        var bg = absenceColor(c, absence.type);
        // Deckend aufhellen, damit sich Band und Kreis nicht überlagern.
        if (freeDay) {
          bg = Color.alphaBlend(bg.withValues(alpha: 0.5), c.surface);
        }
        fg = _absenceOnColor(c, absence.type);
        layers.add(
          _DayShape(
            color: bg,
            left: !first && calc.absenceFor(prev)?.id == absence.id,
            right: !last && calc.absenceFor(next)?.id == absence.id,
          ),
        );
      }
      final halfHoliday = calc.halfHolidayFor(day);
      if (halfHoliday != null) {
        layers.add(
          _DayShape(color: absenceColor(c, AbsenceType.holiday), half: true),
        );
      }
      if (selected) {
        final left = !first && inSel(prev);
        final right = !last && inSel(next);
        final edge = day == selFrom || day == selTo;
        layers.add(
          _DayShape(
            color: c.primary.withValues(alpha: 0.3),
            left: left,
            right: right,
            circle: !edge && !(left && right),
          ),
        );
        if (edge) {
          layers.add(_DayShape(color: c.primary));
          fg = c.onPrimary;
        }
      }
      if (day == today) {
        layers.add(_DayShape(border: Border.all(color: c.primary, width: 1.5)));
      }

      Widget cell = Stack(
        fit: StackFit.expand,
        children: [
          ...layers,
          Center(
            child: Text(
              '$dayNum',
              style: theme.textTheme.bodySmall?.copyWith(
                color: fg,
                fontWeight: day == today ? FontWeight.bold : null,
              ),
            ),
          ),
        ],
      );
      if (absence != null || halfHoliday != null) {
        cell = Tooltip(
          message: [
            formatDate(day),
            if (halfHoliday != null) '${halfHoliday.label} (halber Feiertag)',
            if (absence != null)
              '${absence.label}${halfHoliday != null ? ' (halber Tag)' : ''}'
                  '${!absence.isHoliday && absence.note != null ? ' · ${absence.note}' : ''}',
          ].join('\n'),
          triggerMode: TooltipTriggerMode.manual,
          waitDuration: const Duration(milliseconds: 400),
          child: cell,
        );
      }
      return MetaData(
        metaData: _DayTag(day),
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: cell),
      );
    }

    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                DateFormat.MMMM('de_DE').format(month),
                style: theme.textTheme.titleSmall,
              ),
            ),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.15,
              children: [
                for (var w = 0; w < 7; w++)
                  Center(
                    child: Text(
                      weekdayShort[w],
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (var i = 0; i < cells; i++) dayCell(i),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
