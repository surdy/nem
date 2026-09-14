import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/fixed_schedule.dart';
import '../domain/interval_unit.dart';
import '../domain/schedule.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import 'category_chips.dart';
import 'due_list_screen.dart' show formatDueDate;
import 'fixed_schedule_editor.dart';

/// Creates a task with either kind of schedule (ADR 0005), or edits one that
/// already exists.
///
/// One form for both, like `TargetFormScreen`: the fields that describe a task
/// are the same fields whether it is being invented or corrected, and a second
/// screen would be one that drifts. [task] is what decides which.
///
/// The two modes are two forms, not one form with a toggled meaning: a floating
/// schedule is an interval from the last completion, a fixed one is a calendar
/// rule, and they share nothing but the interval count.
class TaskFormScreen extends ConsumerStatefulWidget {
  const TaskFormScreen({super.key, this.task});

  /// The task being edited, or null when creating one.
  final Task? task;

  @override
  ConsumerState<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends ConsumerState<TaskFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _titleController = TextEditingController(
    text: widget.task?.title ?? '',
  );
  late final _notesController = TextEditingController(
    text: widget.task?.notes ?? '',
  );
  late final _intervalController = TextEditingController(
    text:
        '${_initialDraft?.interval ?? widget.task?.floatingSchedule?.intervalN ?? 3}',
  );

  late ScheduleMode _mode = widget.task?.scheduleMode ?? ScheduleMode.floating;
  late IntervalUnit _unit =
      widget.task?.floatingSchedule?.intervalUnit ?? IntervalUnit.day;

  /// The target this task is done on, or null for work attached to nothing
  /// physical (ADR 0008).
  late String? _targetId = widget.task?.targetId;

  /// The categories this task will be put in (CONTEXT.md — "Category").
  ///
  /// A set rather than a single value, because a task can be in several at
  /// once — which is exactly what distinguishes a category from a target.
  final Set<String> _categoryIds = {};

  late FixedFrequency _frequency =
      _initialDraft?.frequency ?? FixedFrequency.weekly;
  late DateTime _startDate = widget.task?.startDate ?? _today();

  /// The weekdays a weekly fixed rule repeats on, as `DateTime.monday`…
  ///
  /// Starts on the start date's own weekday, and may be emptied — an empty set
  /// writes no `BYDAY`, which RFC 5545 reads as the start date's weekday, so
  /// the schedule means the same thing either way.
  late Set<int> _weekdays = _initialDraft?.weekdays ?? {_startDate.weekday};

  late MonthlyOn _monthlyOn = _initialDraft?.monthlyOn ?? MonthlyOn.dayOfMonth;
  late FixedScheduleEnd _end = _initialDraft?.end ?? const NeverEnds();

  bool _saving = false;

  bool get _isEdit => widget.task != null;

  /// The stored rule taken back apart into the editor's own vocabulary, or null
  /// when there is nothing to take apart — a new task, a floating one, or a
  /// rule this build cannot say (ADR 0006).
  FixedScheduleDraft? get _initialDraft => widget.task?.fixedSchedule?.draft;

  /// Whether the schedule may be edited at all.
  ///
  /// False for a fixed task whose rule the editor cannot author. Such a rule is
  /// shown as itself and left alone: an editor that rendered its best guess
  /// would silently rewrite the rule the moment the title beside it was saved
  /// (ADR 0006). Everything else on the form stays editable.
  bool get _scheduleIsEditable =>
      widget.task?.scheduleMode != ScheduleMode.fixed ||
      (widget.task?.fixedSchedule?.isEditable ?? false);

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  /// Reads the task's memberships once, to start the chips off selected.
  ///
  /// Read from the repository rather than watched through a provider: this is
  /// the form's opening state, not a live view, and a `StreamProvider` nothing
  /// is listening to never subscribes at all (PLAN.md — the Riverpod pausing
  /// trap).
  Future<void> _loadCategories() async {
    final task = widget.task;
    if (task == null) return;
    final ids = await ref
        .read(categoryRepositoryProvider)
        .categoryIdsForTask(task.id);
    if (mounted) setState(() => _categoryIds.addAll(ids));
  }

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

  /// The fixed rule the form currently describes.
  ///
  /// Always present, so the editor below has something to render and summarise
  /// while the interval box is empty or nonsense; [_fixedSchedule] is what
  /// refuses to build a schedule out of that.
  FixedScheduleDraft get _fixedDraft {
    final n = _intervalN;
    return FixedScheduleDraft(
      frequency: _frequency,
      interval: (n == null || n < 1) ? 1 : n,
      weekdays: _weekdays,
      monthlyOn: _monthlyOn,
      end: _end,
      startDate: _startDate,
      zoneId: ref.read(zoneIdProvider),
    );
  }

  FixedSchedule? get _fixedSchedule {
    final n = _intervalN;
    if (n == null || n < 1) return null;
    return _fixedDraft.toSchedule();
  }

  /// Takes the editor's whole draft back apart into the form's own state.
  ///
  /// The start date and the interval stay owned by the form, because both are
  /// shared with the floating mode; everything else the editor decides.
  void _applyDraft(FixedScheduleDraft draft) => setState(() {
    _frequency = draft.frequency;
    _weekdays = draft.weekdays;
    _monthlyOn = draft.monthlyOn;
    _end = draft.end;
  });

  /// The due date this task will have, derived live from the schedule the form
  /// describes. It is shown, never edited (ADR 0004).
  ///
  /// For a fixed schedule this is the first occurrence the rule produces, which
  /// can already be in the past if the start date is — that is the collapse
  /// working as intended, not a preview bug (ADR 0007).
  DateTime? get _previewDueDate {
    // The completion log is an input, not something the form can change: a
    // task being edited already has history, and both modes measure against
    // it (ADR 0004). Null for a new task, which is the no-history case.
    final lastCompletedAt = widget.task?.lastCompletedAt;
    switch (_mode) {
      case ScheduleMode.floating:
        final schedule = _floatingSchedule;
        return schedule == null
            ? null
            : floatingDueDate(schedule, lastCompletedAt: lastCompletedAt);
      case ScheduleMode.fixed:
        final schedule = _fixedSchedule;
        return schedule == null
            ? null
            : fixedDueDate(schedule, lastCompletedAt: lastCompletedAt);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final existing = widget.task;
      final taskId = existing == null
          ? await _create()
          : await _update(existing);
      // After the task rather than with it: a membership is a row of its own
      // pointing at the task, so there has to be a task for it to point at.
      // Written unconditionally when editing, because an emptied set is an
      // edit too — it is how the last category comes off.
      if (taskId != null && (_isEdit || _categoryIds.isNotEmpty)) {
        await ref
            .read(categoryRepositoryProvider)
            .setCategoriesForTask(taskId, _categoryIds);
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String> _create() async {
    final repository = ref.read(taskRepositoryProvider);
    final title = _titleController.text.trim();
    final notes = _notesController.text;
    final task = switch (_mode) {
      ScheduleMode.floating => await repository.createFloatingTask(
        title: title,
        notes: notes,
        targetId: _targetId,
        intervalN: _intervalN!,
        intervalUnit: _unit,
        startDate: _startDate,
      ),
      ScheduleMode.fixed => await repository.createFixedTask(
        title: title,
        notes: notes,
        targetId: _targetId,
        schedule: _fixedSchedule!,
      ),
    };
    return task.id;
  }

  /// Saves an edit, passing a schedule only when the form was allowed to author
  /// one — a rule the editor cannot say is left exactly as stored (ADR 0006).
  ///
  /// Afterwards the whole reminder window is re-planned. The schedule may have
  /// moved, and a reminder is a request to be told *on the days this is due*,
  /// so the days it should fire on have moved with it.
  Future<String?> _update(Task existing) async {
    final editable = _scheduleIsEditable;
    final updated = await ref
        .read(taskRepositoryProvider)
        .updateTask(
          taskId: existing.id,
          title: _titleController.text.trim(),
          notes: _notesController.text,
          targetId: _targetId,
          floatingSchedule: editable && _mode == ScheduleMode.floating
              ? _floatingSchedule
              : null,
          fixedSchedule: editable && _mode == ScheduleMode.fixed
              ? _fixedSchedule
              : null,
        );
    if (updated != null) await ref.read(reminderSchedulerProvider).refresh();
    return updated?.id;
  }

  /// The date picker carries the time of day across, because it cannot ask for
  /// one: a fixed rule authored elsewhere can be anchored at 09:00, and picking
  /// a new date is a statement about the date alone.
  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(
      () => _startDate = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _startDate.hour,
        _startDate.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewDue = _previewDueDate;
    final isFixed = _mode == ScheduleMode.fixed;
    final targets = ref.watch(targetListProvider).value ?? const <Target>[];
    final categories = ref.watch(categoryListProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit task' : 'New task')),
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
            // Offered only once there is something to choose, like the target
            // above: a category is user-defined, so the list is empty until one
            // has been made in Settings.
            if (categories.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Categories (optional)', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final category in categories)
                    FilterChip(
                      avatar: CategorySwatch(color: category.color),
                      label: Text(category.name),
                      selected: _categoryIds.contains(category.id),
                      onSelected: (isSelected) => setState(() {
                        if (isSelected) {
                          _categoryIds.add(category.id);
                        } else {
                          _categoryIds.remove(category.id);
                        }
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 32),
            // A rule the editor cannot author is shown as itself and nothing
            // else: no mode toggle, no interval, no start date, because every
            // one of those controls would be an offer to replace it with
            // something the editor *can* say (ADR 0006).
            if (!_scheduleIsEditable) ...[
              Text('Schedule', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              UneditableRule(rule: widget.task?.rrule ?? ''),
            ] else ...[
              SegmentedButton<ScheduleMode>(
                segments: const [
                  ButtonSegment(
                    value: ScheduleMode.floating,
                    label: Text('Floating'),
                  ),
                  ButtonSegment(
                    value: ScheduleMode.fixed,
                    label: Text('Fixed'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) =>
                    setState(() => _mode = selection.single),
              ),
              const SizedBox(height: 8),
              Text(
                isFixed
                    ? 'Due dates come from the calendar and ignore when the '
                          'work was actually done.'
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
              if (isFixed) ...[
                const SizedBox(height: 16),
                FixedScheduleEditor(draft: _fixedDraft, onChanged: _applyDraft),
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
                  // "First due" is only true of a task with no history. Once
                  // there is a completion behind it, the preview is the next one
                  // and is measured from that completion.
                  title: Text(
                    widget.task?.lastCompletedAt == null
                        ? 'First due'
                        : 'Next due',
                  ),
                  subtitle: Text(formatDueDate(previewDue)),
                  enabled: false,
                ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(
                _saving
                    ? 'Saving…'
                    : _isEdit
                    ? 'Save changes'
                    : 'Create task',
              ),
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
