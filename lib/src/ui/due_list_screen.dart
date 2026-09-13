import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/due_list.dart';
import '../domain/due_status.dart';
import '../domain/task.dart';
import 'create_task_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';
import 'task_detail_screen.dart';

/// The home screen: everything due, grouped Overdue → Today → Soon.
class DueListScreen extends ConsumerWidget {
  const DueListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(dueSectionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Due'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const ScanScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CreateTaskScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
      body: sections.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _Message(text: 'Could not load tasks.\n$error'),
        data: (data) => data.isEmpty
            ? const _Message(
                text: 'Nothing due.\nAdd a task to start tracking it.',
              )
            : _SectionList(sections: data),
      ),
    );
  }
}

class _SectionList extends ConsumerWidget {
  const _SectionList({required this.sections});

  final List<DueSection> sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider);
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final section in sections) ...[
          _SectionHeading(section: section),
          for (final task in section.tasks) _TaskTile(task: task, now: now),
        ],
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.section});

  final DueSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOverdue = section.status == DueStatus.overdue;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        section.heading.toUpperCase(),
        style: theme.textTheme.labelLarge?.copyWith(
          letterSpacing: 1.2,
          color: isOverdue
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// How long the undo affordance stays on screen after a completion.
const _undoWindow = Duration(seconds: 5);

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task, required this.now});

  final Task task;
  final DateTime now;

  /// Records the completion, then offers [_undoWindow] to take it back.
  ///
  /// Nothing is held back while the offer stands: the completion is written
  /// immediately and the task reschedules at once, because undo is a tombstone
  /// and a recomputation rather than a delayed commit (ADR 0004).
  Future<void> _complete(BuildContext context, WidgetRef ref) async {
    final repository = ref.read(taskRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final completion = await repository.recordCompletion(task.id);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Completed ${task.title}'),
          duration: _undoWindow,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => repository.undoCompletion(completion),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final due = task.dueDate;
    final late = due == null ? null : overdueLabel(due, now);
    final schedule = task.scheduleLabel;

    return ListTile(
      leading: IconButton(
        icon: const Icon(Icons.check_circle_outline),
        tooltip: 'Complete',
        onPressed: () => _complete(context, ref),
      ),
      title: Text(task.title),
      subtitle: Text(
        [
          if (due != null) 'Due ${formatDueDate(due)}',
          if (schedule != null) schedule.toLowerCase(),
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
      isThreeLine: task.notes != null,
      // Tapping the row opens the task's history; the tick stays on the
      // leading button, so opening it cannot complete anything by accident.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TaskDetailScreen(taskId: task.id),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
  );
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "14 Mar 2026" — no intl dependency for one format.
String formatDueDate(DateTime due) {
  final local = due.isUtc ? due.toLocal() : due;
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}
