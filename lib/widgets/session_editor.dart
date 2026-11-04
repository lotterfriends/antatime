import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../format.dart';
import '../models.dart';

/// Dialog zum Nacherfassen oder Bearbeiten einer Arbeitszeit.
Future<void> showSessionEditor(
  BuildContext context, {
  WorkSession? session,
  DateTime? day,
}) {
  return showDialog(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<AppState>(),
      child: _SessionEditor(session: session, day: day),
    ),
  );
}

class _SessionEditor extends StatefulWidget {
  const _SessionEditor({this.session, this.day});

  final WorkSession? session;
  final DateTime? day;

  @override
  State<_SessionEditor> createState() => _SessionEditorState();
}

class _SessionEditorState extends State<_SessionEditor> {
  late DateTime _day;
  late TimeOfDay _start;
  TimeOfDay? _end;
  late bool _running;
  late final TextEditingController _note;
  String? _error;

  bool get _isEdit => widget.session != null;

  @override
  void initState() {
    super.initState();
    final s = widget.session;
    if (s != null) {
      _day = dayOf(s.start);
      _start = TimeOfDay.fromDateTime(s.start);
      _end = s.end == null ? null : TimeOfDay.fromDateTime(s.end!);
      _running = s.isRunning;
    } else {
      _day = dayOf(widget.day ?? DateTime.now());
      _start = const TimeOfDay(hour: 8, minute: 0);
      _end = const TimeOfDay(hour: 16, minute: 0);
      _running = false;
    }
    _note = TextEditingController(text: s?.note ?? '');
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  DateTime _combine(DateTime day, TimeOfDay t) =>
      DateTime(day.year, day.month, day.day, t.hour, t.minute);

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d != null) setState(() => _day = d);
  }

  Future<void> _pickStart() async {
    final t = await showTimePicker(context: context, initialTime: _start);
    if (t != null) setState(() => _start = t);
  }

  Future<void> _pickEnd() async {
    final t = await showTimePicker(
        context: context, initialTime: _end ?? TimeOfDay.now());
    if (t != null) setState(() => _end = t);
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final start = _combine(_day, _start);
    DateTime? end;
    if (!_running) {
      if (_end == null) {
        setState(() => _error = 'Bitte ein Ende angeben.');
        return;
      }
      end = _combine(_day, _end!);
      // Ende vor Beginn → über Mitternacht gearbeitet.
      if (!end.isAfter(start)) {
        end = DateTime(end.year, end.month, end.day + 1, end.hour, end.minute);
      }
    } else {
      if (start.isAfter(DateTime.now())) {
        setState(() => _error = 'Beginn liegt in der Zukunft.');
        return;
      }
      final other = state.data.running;
      if (other != null && other.id != widget.session?.id) {
        setState(() => _error = 'Es läuft bereits eine andere Arbeitszeit.');
        return;
      }
    }

    // Überschneidungen prüfen.
    for (final o in state.data.sessions) {
      if (o.id == widget.session?.id) continue;
      final oEnd = o.end ?? DateTime.now();
      final thisEnd = end ?? DateTime.now();
      if (start.isBefore(oEnd) && thisEnd.isAfter(o.start)) {
        setState(() => _error =
            'Überschneidet sich mit ${formatTime(o.start)}–${o.end == null ? 'jetzt' : formatTime(o.end!)}.');
        return;
      }
    }

    final note = _note.text.trim();
    await state.upsertSession(WorkSession(
      id: widget.session?.id ?? newId(),
      start: start,
      end: end,
      note: note.isEmpty ? null : note,
    ));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final state = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Arbeitszeit löschen?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true) {
      await state.deleteSession(widget.session!.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isToday = _day == dayOf(DateTime.now());
    return AlertDialog(
      title: Text(_isEdit ? 'Arbeitszeit bearbeiten' : 'Arbeitszeit nacherfassen'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today),
              title: const Text('Tag'),
              subtitle: Text(formatDate(_day)),
              onTap: _pickDay,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.play_arrow),
              title: const Text('Beginn'),
              subtitle: Text(_start.format(context)),
              onTap: _pickStart,
            ),
            if (isToday || _running)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Läuft noch'),
                value: _running,
                onChanged: (v) => setState(() => _running = v),
              ),
            if (!_running)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.stop),
                title: const Text('Ende'),
                subtitle: Text(_end?.format(context) ?? '–'),
                onTap: _pickEnd,
              ),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Notiz (optional)'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        if (_isEdit)
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
