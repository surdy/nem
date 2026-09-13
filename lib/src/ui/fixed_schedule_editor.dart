import 'package:flutter/material.dart';

import '../domain/fixed_schedule.dart';
import 'due_list_screen.dart' show formatDueDate;

/// Authors the part of a fixed schedule that the frequency alone does not say:
/// which weekdays a weekly rule repeats on, what shape a monthly one takes, and
/// when the whole thing stops. The interval and the frequency sit above it, in
/// the row the two schedule modes share.
///
/// [draft] is null when the task's stored rule is one the editor cannot
/// represent — a rule that reached storage by hand-edit or import, which is
/// expected and allowed, because storage is deliberately more expressive than
/// this editor (ADR 0006). The rule is then shown as itself and read-only. It
/// is never rewritten into the nearest thing the editor could have said, and
/// [onChanged] is never called, so there is nothing to save over it with.
class FixedScheduleEditor extends StatefulWidget {
  const FixedScheduleEditor({
    required this.draft,
    required this.onChanged,
    this.storedRule,
    super.key,
  });

  final FixedScheduleDraft? draft;

  /// The rule exactly as stored, shown when [draft] is null.
  final String? storedRule;

  final ValueChanged<FixedScheduleDraft> onChanged;

  @override
  State<FixedScheduleEditor> createState() => _FixedScheduleEditorState();
}

class _FixedScheduleEditorState extends State<FixedScheduleEditor> {
  /// The date and the count a discarded end condition was carrying.
  ///
  /// Only the chosen one of the three is part of the rule, so flipping to
  /// "never" and back would otherwise throw away a date just picked or a count
  /// just typed.
  DateTime? _lastEndDate;
  int? _lastCount;

  @override
  void initState() {
    super.initState();
    _remember();
  }

  @override
  void didUpdateWidget(covariant FixedScheduleEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _remember();
  }

  void _remember() {
    final end = widget.draft?.end;
    if (end is EndsOnDate) _lastEndDate = end.date;
    if (end is EndsAfter) _lastCount = end.occurrences;
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final onChanged = widget.onChanged;
    if (draft == null) {
      return UneditableRule(rule: widget.storedRule ?? '');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (draft.frequency == FixedFrequency.weekly)
          _WeekdayPicker(
            selected: draft.weekdays,
            fallbackWeekday: draft.startDate.weekday,
            onChanged: (weekdays) =>
                onChanged(draft.copyWith(weekdays: weekdays)),
          ),
        if (draft.frequency == FixedFrequency.monthly)
          _MonthlyShapeField(
            draft: draft,
            onChanged: (on) => onChanged(draft.copyWith(monthlyOn: on)),
          ),
        if (draft.skipsShortMonths)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              // RFC 5545 skips a month that has no such day rather than
              // clamping to its last one, which is the opposite of what a
              // floating monthly interval does (ADR 0005). Say so rather than
              // surprise someone in February — and do not quietly fix it.
              'Months shorter than ${draft.startDate.day} days are skipped.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 16),
        _EndField(
          draft: draft,
          lastEndDate: _lastEndDate,
          lastCount: _lastCount,
          onChanged: (end) => onChanged(draft.copyWith(end: end)),
        ),
        if (draft.endsBeforeItStarts)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'This ends before the start date, so nothing is ever due.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        const SizedBox(height: 16),
        _Summary(text: draft.summary),
      ],
    );
  }
}

/// A stored rule shown as itself, because the editor cannot say it (ADR 0006).
///
/// Verbatim and unparsed: the point is that nem has not understood it and will
/// not touch it. A rule can arrive here by hand-edit or by a future calendar
/// import, and the honest thing is to say so rather than to approximate it.
class UneditableRule extends StatelessWidget {
  const UneditableRule({required this.rule, super.key});

  final String rule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card.filled(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              key: const ValueKey('uneditable-rule'),
              rule,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'nem cannot edit this calendar rule, so it is kept exactly as it is.',
          style: theme.textTheme.bodySmall,
        ),
      ],
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

/// Day of the month or nth weekday — the one choice a monthly rule has.
///
/// Both read off the start date, so the options change with it: the 20th is
/// "the third Tuesday", the 29th is no numbered Tuesday at all and is offered
/// as "the last Tuesday" instead.
class _MonthlyShapeField extends StatelessWidget {
  const _MonthlyShapeField({required this.draft, required this.onChanged});

  final FixedScheduleDraft draft;
  final ValueChanged<MonthlyOn> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<MonthlyOn>(
      // Keyed on the start date, because that is what the options are read
      // off: moving from the 20th to the 29th takes "the third Tuesday" away
      // entirely, and a dropdown holding a value its items no longer offer
      // asserts rather than degrades.
      key: ValueKey('monthly-shape-${draft.startDate}'),
      initialValue: draft.effectiveMonthlyOn,
      decoration: const InputDecoration(labelText: 'Repeats on'),
      items: [
        for (final on in draft.monthlyOptions)
          DropdownMenuItem(value: on, child: Text(_sentence(draft, on))),
      ],
      onChanged: (selected) {
        if (selected != null) onChanged(selected);
      },
    );
  }

  static String _sentence(FixedScheduleDraft draft, MonthlyOn on) {
    final clause = draft.monthlyClause(on);
    return clause[0].toUpperCase() + clause.substring(1);
  }
}

/// Never, on a date, or after a number of occurrences.
class _EndField extends StatelessWidget {
  const _EndField({
    required this.draft,
    required this.lastEndDate,
    required this.lastCount,
    required this.onChanged,
  });

  final FixedScheduleDraft draft;
  final DateTime? lastEndDate;
  final int? lastCount;
  final ValueChanged<FixedScheduleEnd> onChanged;

  _EndChoice get _choice => switch (draft.end) {
    NeverEnds() => _EndChoice.never,
    EndsOnDate() => _EndChoice.onDate,
    EndsAfter() => _EndChoice.afterCount,
  };

  Future<void> _pickDate(BuildContext context, DateTime current) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      // A schedule that ends before it starts has no occurrences at all, which
      // is a task with no due date and nothing to do.
      firstDate: draft.startDate,
      lastDate: DateTime(2100),
    );
    if (picked != null) onChanged(EndsOnDate(picked));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final end = draft.end;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ends', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<_EndChoice>(
          segments: const [
            ButtonSegment(
              value: _EndChoice.never,
              label: Text('Never'),
              tooltip: 'Repeats for ever',
            ),
            ButtonSegment(
              value: _EndChoice.onDate,
              label: Text('On date'),
              tooltip: 'Repeats until a date',
            ),
            ButtonSegment(
              value: _EndChoice.afterCount,
              label: Text('After'),
              tooltip: 'Repeats a number of times',
            ),
          ],
          selected: {_choice},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onChanged(
            switch (selection.single) {
              _EndChoice.never => const NeverEnds(),
              _EndChoice.onDate => EndsOnDate(lastEndDate ?? _aYearOut(draft)),
              _EndChoice.afterCount => EndsAfter(lastCount ?? 10),
            },
          ),
        ),
        switch (end) {
          NeverEnds() => const SizedBox.shrink(),
          EndsOnDate(:final date) => ListTile(
            key: const ValueKey('end-date'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Last day'),
            subtitle: Text(formatDueDate(date)),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: () => _pickDate(context, date),
          ),
          EndsAfter(:final occurrences) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: TextFormField(
                    key: const ValueKey('end-count'),
                    initialValue: '$occurrences',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Occurrences'),
                    onChanged: (value) {
                      final n = int.tryParse(value.trim());
                      if (n != null && n > 0) onChanged(EndsAfter(n));
                    },
                    validator: (value) {
                      final n = int.tryParse((value ?? '').trim());
                      return (n == null || n < 1) ? 'At least 1' : null;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Counted from the start date, however late the work is '
                    'done.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        },
      ],
    );
  }

  /// The date a freshly chosen "on date" starts on: far enough out to be an
  /// obvious placeholder and near enough to be a plausible answer.
  static DateTime _aYearOut(FixedScheduleDraft draft) => DateTime(
    draft.startDate.year + 1,
    draft.startDate.month,
    draft.startDate.day,
  );
}

/// Which end segment is lit. The end condition itself carries a date or a
/// count, which a segment cannot.
enum _EndChoice { never, onDate, afterCount }

/// The rule being built, in plain language, kept live as it is built.
class _Summary extends StatelessWidget {
  const _Summary({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.event_repeat_outlined,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            key: const ValueKey('schedule-summary'),
            style: theme.textTheme.titleSmall,
          ),
        ),
      ],
    );
  }
}
