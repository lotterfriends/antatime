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
  bool _saving = false;
  final String _newId = newId();

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

  /// Ende vor Beginn → über Mitternacht gearbeitet (Ende am Folgetag).
  bool get _overnight =>
      !_running &&
      _end != null &&
      (_end!.hour * 60 + _end!.minute) < (_start.hour * 60 + _start.minute);

  /// Uhrzeit aus dem Editor; unverändert übernommene Zeiten behalten ihre
  /// Sekunden (sonst würde schon das Bearbeiten der Notiz sie abschneiden).
  DateTime _time(DateTime day, TimeOfDay t, DateTime? original) {
    final d = _combine(day, t);
    if (original != null &&
        d == DateTime(original.year, original.month, original.day,
            original.hour, original.minute)) {
      return original;
    }
    return d;
  }

  Future<void> _save() async {
    if (_saving) return;
    final state = context.read<AppState>();
    final original = widget.session;
    final start = _time(_day, _start, original?.start);
    DateTime? end;
    if (!_running) {
      if (_end == null) {
        setState(() => _error = 'Bitte ein Ende angeben.');
        return;
      }
      final endDay = _overnight
          ? DateTime(_day.year, _day.month, _day.day + 1)
          : _day;
      end = _time(endDay, _end!, original?.end);
      if (_overnight && end.difference(start) > maxOvernight) {
        setState(() => _error = 'Ende liegt vor dem Beginn.');
        return;
      }
    }
    final note = _note.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await state.upsertSession(
      WorkSession(
        // Einmal vergeben: Ein zweiter Klick legt keinen zweiten Eintrag an.
        id: original?.id ?? _newId,
        start: start,
        end: end,
        note: note.isEmpty ? null : note,
      ),
      original: original?.copy(),
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }
    Navigator.pop(context);
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
                subtitle: Text(_end == null
                    ? '–'
                    : _overnight
                        ? '${_end!.format(context)} (am nächsten Tag)'
                        : _end!.format(context)),
                onTap: _pickEnd,
              ),
            TextField(
              controller: _note,
              // Lange Notizen passen nicht mehr in einen Sync-Datensatz.
              maxLength: maxNoteLength,
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
        FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('Speichern')),
      ],
    );
  }
}
