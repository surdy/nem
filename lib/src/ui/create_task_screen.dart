import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/fixed_schedule.dart';
import '../domain/interval_unit.dart';
import '../domain/schedule.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import 'due_list_screen.dart' show formatDueDate;

/// Creates a task with either kind of schedule (ADR 0005).
///
/// The two modes are two forms, not one form with a toggled meaning: a floating
/// schedule is an interval from the last completion, a fixed one is a calendar
/// rule, and they share nothing but the interval count.
class CreateTaskScreen extends ConsumerStatefulWidget {
  const CreateTaskScreen({super.key});

  @override
  ConsumerState<CreateTaskScreen> createState() => _CreateTaskScreenState();
}

class _CreateTaskScreenState extends ConsumerState<CreateTaskScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _intervalController = TextEditingController(text: '3');

  ScheduleMode _mode = ScheduleMode.floating;
  IntervalUnit _unit = IntervalUnit.day;

  /// The target this task is done on, or null for work attached to nothing
  /// physical (ADR 0008).
  String? _targetId;

  FixedFrequency _frequency = FixedFrequency.weekly;
  late DateTime _startDate = _today();

  /// The weekdays a weekly fixed rule repeats on, as `DateTime.monday`…
  ///
  /// Starts on the start date's own weekday, and may be emptied — an empty set
  /// writes no `BYDAY`, which RFC 5545 reads as the start date's weekday, so
  /// the schedule means the same thing either way.
  late Set<int> _weekdays = {_startDate.weekday};

  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  int? get _intervalN => int.tryParse(_intervalController.text.trim());

  FloatingSchedule? get _floatingSchedule {
    final n = _intervalN;
    if (n == null || n < 1) return null;
    return FloatingSchedule(
      intervalN: n,
      intervalUnit: _unit,
      startDate: _startDate,
    );
  }

  FixedSchedule? get _fixedSchedule {
    final n = _intervalN;
    if (n == null || n < 1) return null;
    return FixedSchedule.build(
      frequency: _frequency,
      interval: n,
      weekdays: _weekdays,
      startDate: _startDate,
      zoneId: ref.read(zoneIdProvider),
    );
  }

  /// The due date this task will have, derived live from the schedule the form
  /// describes. It is shown, never edited (ADR 0004).
  ///
  /// For a fixed schedule this is the first occurrence the rule produces, which
  /// can already be in the past if the start date is — that is the collapse
  /// working as intended, not a preview bug (ADR 0007).
  DateTime? get _previewDueDate {
    switch (_mode) {
      case ScheduleMode.floating:
        final schedule = _floatingSchedule;
        return schedule == null ? null : floatingDueDate(schedule);
      case ScheduleMode.fixed:
        final schedule = _fixedSchedule;
        return schedule == null ? null : fixedDueDate(schedule);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final repository = ref.read(taskRepositoryProvider);
      final title = _titleController.text.trim();
      final notes = _notesController.text;
      switch (_mode) {
        case ScheduleMode.floating:
          await repository.createFloatingTask(
            title: title,
            notes: notes,
            targetId: _targetId,
            intervalN: _intervalN!,
            intervalUnit: _unit,
            startDate: _startDate,
          );
        case ScheduleMode.fixed:
          await repository.createFixedTask(
            title: title,
            notes: notes,
            targetId: _targetId,
            schedule: _fixedSchedule!,
          );
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _startDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewDue = _previewDueDate;
    final isFixed = _mode == ScheduleMode.fixed;
    final targets = ref.watch(targetListProvider).value ?? const <Target>[];

    return Scaffold(
      appBar: AppBar(title: const Text('New task')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Replace the water filter',
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Give the task a title'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            // Offered only once there is something to choose. A target is a
            // physical place or object, so the list is empty until one has been
            // created, and an empty dropdown is just a dead control.
            if (targets.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: _targetId,
                decoration: const InputDecoration(
                  labelText: 'Target (optional)',
                ),
                items: [
                  const DropdownMenuItem<String?>(child: Text('No target')),
                  for (final target in targets)
                    DropdownMenuItem<String?>(
                      value: target.id,
                      child: Text(target.name),
                    ),
                ],
                onChanged: (value) => setState(() => _targetId = value),
              ),
            ],
            const SizedBox(height: 32),
            SegmentedButton<ScheduleMode>(
              segments: const [
                ButtonSegment(
                  value: ScheduleMode.floating,
                  label: Text('Floating'),
                ),
                ButtonSegment(value: ScheduleMode.fixed, label: Text('Fixed')),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) =>
                  setState(() => _mode = selection.single),
            ),
            const SizedBox(height: 8),
            Text(
              isFixed
                  ? 'Due dates come from the calendar and ignore when the work '
                        'was actually done.'
                  : 'Due date is measured forward from the last completion.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: TextFormField(
                    controller: _intervalController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Every'),
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final n = int.tryParse((value ?? '').trim());
                      if (n == null || n < 1) return 'At least 1';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: isFixed
                      ? _FrequencyField(
                          value: _frequency,
                          count: _intervalN ?? 1,
                          onChanged: (value) =>
                              setState(() => _frequency = value),
                        )
                      : _UnitField(
                          value: _unit,
                          count: _intervalN ?? 1,
                          onChanged: (value) => setState(() => _unit = value),
                        ),
                ),
              ],
            ),
            if (isFixed && _frequency == FixedFrequency.weekly) ...[
              const SizedBox(height: 16),
              _WeekdayPicker(
                selected: _weekdays,
                fallbackWeekday: _startDate.weekday,
                onChanged: (value) => setState(() => _weekdays = value),
              ),
            ],
            if (isFixed &&
                _frequency == FixedFrequency.monthly &&
                _startDate.day > 28) ...[
              const SizedBox(height: 8),
              Text(
                // RFC 5545 skips a month that has no such day rather than
                // clamping to its last one, which is the opposite of what a
                // floating monthly interval does. Say so rather than surprise
                // someone in February.
                'Months shorter than ${_startDate.day} days are skipped.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start date'),
              subtitle: Text(formatDueDate(_startDate)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: _pickStartDate,
            ),
            if (previewDue != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('First due'),
                subtitle: Text(formatDueDate(previewDue)),
                enabled: false,
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Create task'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The unit of a floating interval — "days", "weeks", "months", "years".
class _UnitField extends StatelessWidget {
  const _UnitField({
    required this.value,
    required this.count,
    required this.onChanged,
  });

  final IntervalUnit value;
  final int count;
  final ValueChanged<IntervalUnit> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<IntervalUnit>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Unit'),
      items: [
        for (final unit in IntervalUnit.values)
          DropdownMenuItem(
            value: unit,
            child: Text(unit.labelFor(count).split(' ').last),
          ),
      ],
      onChanged: (selected) {
        if (selected != null) onChanged(selected);
      },
    );
  }
}

/// The `FREQ` of a fixed rule, worded as the same units the floating form uses.
class _FrequencyField extends StatelessWidget {
  const _FrequencyField({
    required this.value,
    required this.count,
    required this.onChanged,
  });

  final FixedFrequency value;
  final int count;
  final ValueChanged<FixedFrequency> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<FixedFrequency>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Frequency'),
      items: [
        for (final frequency in FixedFrequency.values)
          DropdownMenuItem(
            value: frequency,
            child: Text(frequency.unit.labelFor(count).split(' ').last),
          ),
      ],
      onChanged: (selected) {
        if (selected != null) onChanged(selected);
      },
    );
  }
}

/// Which weekdays a weekly fixed rule repeats on — `BYDAY`.
///
/// Selecting none is allowed and means the start date's own weekday, which is
/// what RFC 5545 does with an absent `BYDAY`.
class _WeekdayPicker extends StatelessWidget {
  const _WeekdayPicker({
    required this.selected,
    required this.fallbackWeekday,
    required this.onChanged,
  });

  final Set<int> selected;
  final int fallbackWeekday;
  final ValueChanged<Set<int>> onChanged;

  static const _initials = {
    DateTime.monday: 'M',
    DateTime.tuesday: 'T',
    DateTime.wednesday: 'W',
    DateTime.thursday: 'T',
    DateTime.friday: 'F',
    DateTime.saturday: 'S',
    DateTime.sunday: 'S',
  };

  static const _names = {
    DateTime.monday: 'Monday',
    DateTime.tuesday: 'Tuesday',
    DateTime.wednesday: 'Wednesday',
    DateTime.thursday: 'Thursday',
    DateTime.friday: 'Friday',
    DateTime.saturday: 'Saturday',
    DateTime.sunday: 'Sunday',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Repeats on', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final weekday in _initials.keys)
              FilterChip(
                key: ValueKey('weekday-$weekday'),
                label: Text(_initials[weekday]!),
                tooltip: _names[weekday],
                selected: selected.contains(weekday),
                showCheckmark: false,
                onSelected: (isSelected) {
                  final next = {...selected};
                  if (isSelected) {
                    next.add(weekday);
                  } else {
                    next.remove(weekday);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
        if (selected.isEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Repeats on ${_names[fallbackWeekday]}, from the start date.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
