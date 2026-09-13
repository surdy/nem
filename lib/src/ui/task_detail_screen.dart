import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/completion.dart';
import '../domain/completion_history.dart';
import '../domain/due_status.dart';
import '../domain/task.dart';
import 'due_list_screen.dart' show formatDueDate;
import 'fixed_schedule_editor.dart' show UneditableRule;
import 'task_actions.dart';

/// A task and everything its completion log says about it.
///
/// Read-only, and read straight from the log (ADR 0004): the dates, the gaps
/// and the window counts all come from the `completions` rows, never from
/// `tasks.due_date` or `tasks.last_completed_at`. Those are sort caches, and a
/// history that agreed with a stale one would hide the very thing this screen
/// is for.
class TaskDetailScreen extends ConsumerWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(taskProvider(taskId));
    final history = ref.watch(taskHistoryProvider(taskId));
    final now = ref.watch(nowProvider);
    final loaded = task.value;

    return Scaffold(
      appBar: AppBar(
        title: Text(loaded?.title ?? 'Task'),
        actions: [
          // Snooze, archive and their undos live here as well as on the due
          // list row, because this is the only place an archived task can be
          // reached from at all.
          if (loaded != null) TaskActionsMenu(task: loaded, now: now),
        ],
      ),
      body: switch ((task, history)) {
        (AsyncError(:final error), _) || (_, AsyncError(:final error)) =>
          _Message(text: 'Could not load this task.\n$error'),
        (AsyncData(value: final task?), AsyncData(value: final history)) =>
          _Detail(task: task, history: history),
        (AsyncData(value: null), _) => const _Message(
          text: 'This task no longer exists.',
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Detail extends ConsumerWidget {
  const _Detail({required this.task, required this.history});

  final Task task;
  final TaskHistory history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider);
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _Schedule(task: task, now: now),
        _Summaries(summaries: history.summaries),
        const _Heading('History'),
        if (history.isEmpty)
          const _Message(
            text: 'No completions yet.\nThe first one starts the history.',
          )
        else
          for (final entry in history.entries) _EntryTile(entry: entry),
      ],
    );
  }
}

class _Schedule extends StatelessWidget {
  const _Schedule({required this.task, required this.now});

  final Task task;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = task.dueDate;
    final late = due == null ? null : overdueLabel(due, now);
    final fixed = task.fixedSchedule;
    // A rule nem cannot say in words is shown as itself below rather than
    // described here, so the heading is never a paraphrase of something that
    // was not understood (ADR 0006).
    final label =
        task.floatingSchedule?.label ??
        (fixed != null && fixed.isEditable ? fixed.label : null);
    final storedRule = task.scheduleMode == ScheduleMode.fixed && label == null
        ? task.rrule
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) Text(label, style: theme.textTheme.titleMedium),
          if (storedRule != null) UneditableRule(rule: storedRule),
          if (due != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Due ${formatDueDate(due)}${late == null ? '' : ' · $late'}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: late == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
            ),
          // The due date above IS the snooze date while a snooze is holding, so
          // the chip says which kind of date it is rather than repeating it.
          if (task.isSnoozedAt(now) || task.isArchived)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                spacing: 8,
                children: [
                  if (task.isSnoozedAt(now)) const SnoozedChip(),
                  if (task.isArchived)
                    Chip(
                      avatar: const Icon(Icons.archive_outlined, size: 16),
                      label: const Text('Archived'),
                      labelStyle: theme.textTheme.labelSmall,
                      side: BorderSide.none,
                      backgroundColor: theme.colorScheme.surfaceContainerHigh,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          if (task.notes != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(task.notes!, style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
  }
}

/// The trailing-window counts, side by side.
class _Summaries extends StatelessWidget {
  const _Summaries({required this.summaries});

  final List<HistorySummary> summaries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Row(
        spacing: 8,
        children: [
          for (final summary in summaries)
            Expanded(
              child: Card.filled(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.windowLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        summary.countLabel,
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completedAt = entry.completedAt.isUtc
        ? entry.completedAt.toLocal()
        : entry.completedAt;
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(completedAt));
    final late = entry.lateLabel;

    return ListTile(
      leading: Icon(_iconFor(entry.source)),
      title: Text('${formatDueDate(completedAt)} · $time'),
      subtitle: Text(
        [
          entry.source.displayLabel,
          // The gap is what makes a missed occurrence visible: ADR 0007 keeps
          // it off the due list, and only the log remembers it happened.
          ?entry.gapLabel,
          ?entry.completion.note,
        ].join(' · '),
      ),
      trailing: late == null
          ? null
          : Chip(
              label: Text(late),
              labelStyle: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
              backgroundColor: theme.colorScheme.errorContainer,
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
    );
  }

  static IconData _iconFor(CompletionSource source) => switch (source) {
    CompletionSource.manual => Icons.check_circle_outline,
    CompletionSource.tag => Icons.nfc,
    CompletionSource.label => Icons.qr_code_2,
    CompletionSource.barcode => Icons.barcode_reader,
  };
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelLarge?.copyWith(
          letterSpacing: 1.2,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyLarge,
    ),
  );
}
