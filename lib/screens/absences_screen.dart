import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../click_cursor.dart';
import '../format.dart';
import '../models.dart';
import '../widgets/absence_year_view.dart';

IconData absenceIcon(AbsenceType t) => switch (t) {
  AbsenceType.sick => Icons.sick_outlined,
  AbsenceType.vacation => Icons.beach_access_outlined,
  AbsenceType.other => Icons.event_busy_outlined,
  AbsenceType.holiday => Icons.celebration_outlined,
};

class AbsencesScreen extends StatefulWidget {
  const AbsencesScreen({super.key});

  @override
  State<AbsencesScreen> createState() => _AbsencesScreenState();
}

class _AbsencesScreenState extends State<AbsencesScreen> {
  /// Jahresansicht statt Liste.
  bool _yearView = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final calc = state.calc;
    final year = state.now.year;
    // Feiertage des laufenden und des nächsten Jahres automatisch anzeigen.
    final absences = [
      ...state.data.absences,
      ...calc.holidaysIn(year),
      ...calc.holidaysIn(year + 1),
      ...calc.halfHolidaysIn(year),
      ...calc.halfHolidaysIn(year + 1),
    ]..sort((a, b) => b.from.compareTo(a.from));
    final federalState = state.data.settings.federalState;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Abwesenheiten'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.view_list_outlined),
                  tooltip: 'Liste',
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.calendar_view_month),
                  tooltip: 'Jahresansicht',
                ),
              ],
              selected: {_yearView},
              onSelectionChanged: (s) => setState(() => _yearView = s.first),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAbsenceEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('Abwesenheit'),
      ),
      body: _yearView
          ? const AbsenceYearView()
          : absences.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Noch keine Abwesenheiten.\n\nKrank, Urlaub oder andere '
                  'Abwesenheiten zählen an Arbeitstagen wie ein voll '
                  'gearbeiteter Tag.\n\nFeiertage werden automatisch '
                  'eingetragen, wenn in den Einstellungen ein Bundesland '
                  'gewählt ist.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: absences.length,
              itemBuilder: (context, i) {
                final a = absences[i];
                final range = a.from == a.to
                    ? formatDate(a.from)
                    : '${formatDateShort(a.from)} – ${formatDateShort(a.to)}';
                // Arbeitstage ohne Feiertage (z. B. verbrauchte Urlaubstage).
                final n = calc.workdaysOf(a);
                if (a.isHoliday) {
                  return ListTile(
                    leading: Icon(
                      absenceIcon(a.type),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(a.label),
                    subtitle: Text(
                      '$range · '
                      '${a.half ? 'Halber Feiertag' : 'Feiertag ${federalState?.label ?? ''}'}'
                      '${n == 0 ? ' · kein Arbeitstag' : ''}',
                    ),
                  );
                }
                return ListTile(
                  leading: Icon(absenceIcon(a.type)),
                  title: Text(a.label),
                  subtitle: Text(
                    '$range · ${formatWorkdays(n)}${a.note != null ? '\n${a.note}' : ''}',
                  ),
                  isThreeLine: a.note != null,
                  onTap: () => showAbsenceEditor(context, absence: a),
                );
              },
            ),
    );
  }
}

/// Öffnet den Dialog für eine neue oder vorhandene [absence]. Eine neue
/// Abwesenheit beginnt mit [range] bzw. dem Tag [day] (sonst heute).
Future<void> showAbsenceEditor(
  BuildContext context, {
  Absence? absence,
  DateTime? day,
  DateTimeRange? range,
}) {
  return showDialog(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<AppState>(),
      child: _AbsenceEditor(absence: absence, day: day, range: range),
    ),
  );
}

class _AbsenceEditor extends StatefulWidget {
  const _AbsenceEditor({this.absence, this.day, this.range});

  final Absence? absence;
  final DateTime? day;
  final DateTimeRange? range;

  @override
  State<_AbsenceEditor> createState() => _AbsenceEditorState();
}

class _AbsenceEditorState extends State<_AbsenceEditor> {
  late AbsenceType _type;
  late DateTimeRange _range;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    final a = widget.absence;
    _type = a?.type ?? AbsenceType.vacation;
    final d = dayOf(widget.day ?? DateTime.now());
    _range = a != null
        ? DateTimeRange(start: a.from, end: a.to)
        : widget.range ?? DateTimeRange(start: d, end: d);
    _note = TextEditingController(text: a?.note ?? '');
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  static DateTime _latest(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: _range.start.isBefore(DateTime(2000))
          ? _range.start
          : DateTime(2000),
      lastDate: _latest(
        DateTime.now().add(const Duration(days: 3 * 365)),
        _range.end,
      ),
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _save() async {
    final note = _note.text.trim();
    await context.read<AppState>().upsertAbsence(
      Absence(
        id: widget.absence?.id ?? newId(),
        type: _type,
        from: _range.start,
        to: _range.end,
        note: note.isEmpty ? null : note,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    await context.read<AppState>().deleteAbsence(widget.absence!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final single = _range.start == _range.end;
    final calc = context.watch<AppState>().calc;
    final draft = Absence(
      id: '',
      type: _type,
      from: _range.start,
      to: _range.end,
    );
    // Halbe Feiertage im Zeitraum: dort zählt die Abwesenheit nur halb.
    final halfDays = [
      for (
        var d = _range.start;
        !d.isAfter(_range.end);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        if (calc.settings.workdays.contains(d.weekday) &&
            calc.halfHolidayFor(d) != null)
          calc.halfHolidayFor(d)!,
    ];
    return AlertDialog(
      title: Text(
        widget.absence == null
            ? 'Abwesenheit eintragen'
            : 'Abwesenheit bearbeiten',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in AbsenceType.editable)
                  ChoiceChip(
                    mouseCursor: clickCursor,
                    showCheckmark: false,
                    avatar: Icon(absenceIcon(t), size: 18),
                    label: Text(t.label),
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.date_range),
              title: Text(single ? 'Tag' : 'Zeitraum'),
              subtitle: Text(
                '${single ? formatDate(_range.start) : '${formatDateShort(_range.start)} – ${formatDateShort(_range.end)}'}'
                '\n${formatWorkdays(calc.workdaysOf(draft))}',
              ),
              onTap: _pickRange,
            ),
            if (halfDays.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(absenceIcon(AbsenceType.holiday)),
                title: Text(halfDays.map((h) => h.label).join(', ')),
                subtitle: Text(
                  halfDays.length == 1 && single
                      ? 'Halber Feiertag – nur ein halber Tag ${_type.label}'
                      : 'Halbe Feiertage – zählen nur als halber Tag',
                ),
              ),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Notiz (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.absence != null)
          TextButton(
            onPressed: _delete,
            child: Text(
              'Löschen',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _save, child: const Text('Speichern')),
      ],
    );
  }
}
