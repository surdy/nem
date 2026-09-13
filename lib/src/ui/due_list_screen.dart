import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/category.dart';
import '../domain/due_list.dart';
import '../domain/due_status.dart';
import '../domain/task.dart';
import 'archived_tasks_screen.dart';
import 'category_chips.dart';
import 'create_task_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';
import 'task_actions.dart';
import 'task_detail_screen.dart';

/// The home screen: everything due, grouped Overdue → Today → Soon, narrowed to
/// the categories the filter names.
class DueListScreen extends ConsumerWidget {
  const DueListScreen({super.key});

  /// Opens the category picker and applies whatever comes back.
  ///
  /// The choice is written straight through to `sync_state`, so it is still
  /// there on the next launch — a filter that quietly reset itself overnight
  /// would be worse than no filter at all, because the list would look like the
  /// whole list and not be it.
  static Future<void> _pickFilter(
    BuildContext context,
    WidgetRef ref,
    Set<String> selected,
  ) async {
    final picked = await showCategorySelector(
      context: context,
      selected: selected,
      title: 'Filter by category',
    );
    if (picked == null) return;
    await ref.read(categoryFilterProvider.notifier).select(picked);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(dueSectionsProvider);
    final filter = ref.watch(categoryFilterProvider).value ?? const <String>{};
    final categories = ref.watch(categoryListProvider).value ?? const [];
    final filtered = [
      for (final category in categories)
        if (filter.contains(category.id)) category,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Due'),
        actions: [
          IconButton(
            icon: Icon(
              filtered.isEmpty ? Icons.filter_list : Icons.filter_list_alt,
              color: filtered.isEmpty
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
            tooltip: 'Filter by category',
            onPressed: () => _pickFilter(context, ref, filter),
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const ScanScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.archive_outlined),
            tooltip: 'Archived',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ArchivedTasksScreen(),
              ),
            ),
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
        // An explicit tag, because `HomeShell` keeps this screen and the
        // target list alive together in an `IndexedStack` and both have a
        // button. Two heroes sharing the default tag in one subtree is an
        // assertion the moment anything pushes a route over them — which a
        // tapped reminder does.
        heroTag: 'new-task',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CreateTaskScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
      body: Column(
        children: [
          if (filtered.isNotEmpty) _FilterBar(categories: filtered),
          Expanded(
            child: sections.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) =>
                  _Message(text: 'Could not load tasks.\n$error'),
              data: (data) => data.isEmpty
                  ? _Message(
                      text: filtered.isEmpty
                          ? 'Nothing due.\nAdd a task to start tracking it.'
                          : 'Nothing due in '
                                '${_names(filtered)}.\n'
                                'Clear the filter to see everything.',
                    )
                  : _SectionList(sections: data),
            ),
          ),
        ],
      ),
    );
  }

  /// "kitchen", "kitchen and car", "kitchen, car and admin".
  static String _names(List<Category> categories) {
    final names = [for (final category in categories) category.name];
    if (names.length == 1) return names.single;
    return '${names.take(names.length - 1).join(', ')} and ${names.last}';
  }
}

/// What the due list is currently narrowed to, and the way back out of it.
///
/// On screen rather than only behind the app bar's icon, because a filtered
/// list is indistinguishable from a short one: the difference between "nothing
/// is due" and "nothing is due in the kitchen" is the whole of why the strip
/// exists.
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.categories});

  final List<Category> categories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.read(categoryFilterProvider.notifier);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final category in categories)
                    CategoryChip(
                      category: category,
                      onDeleted: () => filter.toggle(category.id),
                    ),
                ],
              ),
            ),
            TextButton(onPressed: filter.clear, child: const Text('Clear')),
          ],
        ),
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
    // Through [TaskCompletions] rather than the repository, so the task's
    // pending reminders go with the completion (CONTEXT.md — "Reminder").
    final completions = ref.read(taskCompletionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final completion = await completions.record(task.id);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Completed ${task.title}'),
          duration: _undoWindow,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => completions.undo(completion),
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
    // A snoozed task sits in Soon alongside everything merely upcoming, so the
    // chip is what tells the two apart.
    final isSnoozed = task.isSnoozedAt(now);

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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSnoozed)
            const SnoozedChip()
          else if (late != null)
            Chip(
              label: Text(late),
              labelStyle: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
              backgroundColor: theme.colorScheme.errorContainer,
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          TaskActionsMenu(task: task, now: now),
        ],
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
