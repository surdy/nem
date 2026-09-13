import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/task.dart';
import 'due_list_screen.dart' show formatDueDate;
import 'task_detail_screen.dart';

/// The tasks that have been retired: off the due list, still on disk, still
/// carrying every completion they ever had.
///
/// Browsing them is half of what archiving is for — the other half is being
/// able to put one back.
class ArchivedTasksScreen extends ConsumerWidget {
  const ArchivedTasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(archivedTasksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Archived')),
      body: tasks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            _Message(text: 'Could not load archived tasks.\n$error'),
        data: (tasks) => tasks.isEmpty
            ? const _Message(
                text: 'Nothing archived.\nTasks you retire are kept here.',
              )
            : ListView(
                children: [for (final task in tasks) _ArchivedTile(task: task)],
              ),
      ),
    );
  }
}

class _ArchivedTile extends ConsumerWidget {
  const _ArchivedTile({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = task.lastCompletedAt;
    final schedule = task.scheduleLabel;

    return ListTile(
      leading: const Icon(Icons.archive_outlined),
      title: Text(task.title),
      // The history is the reason the row still exists, so the row says what
      // there is of it rather than showing a due date nothing is counting
      // against.
      subtitle: Text(
        [
          if (schedule != null) schedule.toLowerCase(),
          last == null
              ? 'never completed'
              : 'last done ${formatDueDate(last)}',
        ].join(' · '),
      ),
      trailing: TextButton(
        onPressed: () =>
            ref.read(taskRepositoryProvider).restoreTask(task.id),
        child: const Text('Restore'),
      ),
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
