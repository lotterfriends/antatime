import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../click_cursor.dart';
import '../format.dart';
import '../models.dart';

IconData absenceIcon(AbsenceType t) => switch (t) {
      AbsenceType.sick => Icons.sick_outlined,
      AbsenceType.vacation => Icons.beach_access_outlined,
      AbsenceType.other => Icons.event_busy_outlined,
      AbsenceType.holiday => Icons.celebration_outlined,
    };

class AbsencesScreen extends StatelessWidget {
  const AbsencesScreen({super.key});

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
    ]..sort((a, b) => b.from.compareTo(a.from));
    final workdays = state.data.settings.workdays;
    final federalState = state.data.settings.federalState;

    // Arbeitstage ohne Feiertage (z. B. verbrauchte Urlaubstage).
    int countWorkdays(Absence a) {
      var n = 0;
      for (var d = a.from;
          !d.isAfter(a.to);
          d = DateTime(d.year, d.month, d.day + 1)) {
        if (workdays.contains(d.weekday) &&
            (a.isHoliday || calc.holidayFor(d) == null)) {
          n++;
        }
      }
      return n;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Abwesenheiten')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAbsenceEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('Abwesenheit'),
      ),
      body: absences.isEmpty
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
                final n = countWorkdays(a);
                if (a.isHoliday) {
                  return ListTile(
                    leading: Icon(absenceIcon(a.type),
                        color: Theme.of(context).colorScheme.primary),
                    title: Text(a.label),
                    subtitle: Text(
                        '$range · Feiertag ${federalState?.label ?? ''}'
                        '${n == 0 ? ' · kein Arbeitstag' : ''}'),
                  );
                }
                return ListTile(
                  leading: Icon(absenceIcon(a.type)),
                  title: Text(a.label),
                  subtitle: Text(
                      '$range · $n Arbeitstag${n == 1 ? '' : 'e'}${a.note != null ? '\n${a.note}' : ''}'),
                  isThreeLine: a.note != null,
                  onTap: () => showAbsenceEditor(context, absence: a),
                );
              },
            ),
    );
  }
}

Future<void> showAbsenceEditor(BuildContext context,
    {Absence? absence, DateTime? day}) {
  return showDialog(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<AppState>(),
      child: _AbsenceEditor(absence: absence, day: day),
    ),
  );
}

class _AbsenceEditor extends StatefulWidget {
  const _AbsenceEditor({this.absence, this.day});

  final Absence? absence;
  final DateTime? day;

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
        : DateTimeRange(start: d, end: d);
    _note = TextEditingController(text: a?.note ?? '');
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 3 * 365)),
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _save() async {
    final note = _note.text.trim();
    await context.read<AppState>().upsertAbsence(Absence(
          id: widget.absence?.id ?? newId(),
          type: _type,
          from: _range.start,
          to: _range.end,
          note: note.isEmpty ? null : note,
        ));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    await context.read<AppState>().deleteAbsence(widget.absence!.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final single = _range.start == _range.end;
    return AlertDialog(
      title: Text(widget.absence == null
          ? 'Abwesenheit eintragen'
          : 'Abwesenheit bearbeiten'),
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
              subtitle: Text(single
                  ? formatDate(_range.start)
                  : '${formatDateShort(_range.start)} – ${formatDateShort(_range.end)}'),
              onTap: _pickRange,
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
            child: Text('Löschen',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(onPressed: _save, child: const Text('Speichern')),
      ],
    );
  }
}
