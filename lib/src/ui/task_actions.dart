import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/snooze.dart';
import '../domain/task.dart';

/// How long the undo affordance stays on screen after a snooze or an archive.
///
/// The same five seconds a completion gets, for the same reason: both are one
/// tap from a menu, and both are cheap to take back because neither writes
/// anything to the completion log.
const taskActionUndoWindow = Duration(seconds: 5);

/// The menu of things you can do to a task without completing it: push it out,
/// take that back, retire it, bring it back.
///
/// Shared between the due list row and the task detail screen so there is one
/// answer to "what can I do to this task" and one set of words for it.
class TaskActionsMenu extends ConsumerWidget {
  const TaskActionsMenu({required this.task, required this.now, super.key});

  final Task task;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSnoozed = task.isSnoozedAt(now);
    return PopupMenuButton<_Choice>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'More',
      onSelected: (choice) => _run(context, ref, choice),
      itemBuilder: (context) => [
        if (!task.isArchived)
          for (final option in snoozeOptions)
            PopupMenuItem<_Choice>(
              value: _Snooze(option),
              child: Text('Snooze ${option.label}'),
            ),
        if (isSnoozed)
          const PopupMenuItem<_Choice>(
            value: _CancelSnooze(),
            child: Text('Cancel snooze'),
          ),
        if (task.isArchived)
          const PopupMenuItem<_Choice>(
            value: _Restore(),
            child: Text('Restore'),
          )
        else
          const PopupMenuItem<_Choice>(
            value: _Archive(),
            child: Text('Archive'),
          ),
        // Last, and separated, because it is the one thing here that is not
        // undoable from a snackbar: archiving keeps everything and this keeps
        // nothing but the completion log.
        const PopupMenuDivider(),
        const PopupMenuItem<_Choice>(
          value: _Delete(),
          child: Text('Delete task'),
        ),
      ],
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref, _Choice choice) async {
    final repository = ref.read(taskRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);

    switch (choice) {
      case _Snooze(:final option):
        await repository.snoozeTask(
          task.id,
          n: option.n,
          unit: option.unit,
          now: now,
        );
        _offerUndo(
          messenger,
          'Snoozed ${task.title} for ${option.label}',
          () => repository.cancelSnooze(task.id),
        );
      case _CancelSnooze():
        await repository.cancelSnooze(task.id, now: now);
      case _Archive():
        await repository.archiveTask(task.id, now: now);
        _offerUndo(
          messenger,
          'Archived ${task.title}',
          () => repository.restoreTask(task.id),
        );
      case _Restore():
        await repository.restoreTask(task.id, now: now);
      case _Delete():
        if (!await _confirmDelete(context)) return;
        // Through `TaskDeletion` rather than the repository, because deleting a
        // task also deletes its reference photos — rows, cached files and the
        // objects in Storage — and the order those go in matters.
        await ref.read(taskDeletionProvider).delete(task.id);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Deleted ${task.title}')));
    }
  }

  /// Asks first, because there is no undo.
  ///
  /// The same shape as deleting a target (`target_detail_screen.dart`), and
  /// the dialog says what is kept and what is not: the completion log survives
  /// a deleted task (ADR 0004), the photos do not.
  Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${task.title}?'),
        content: const Text(
          'The task and its reference photos are deleted on both devices. '
          'Archive it instead to keep it and its history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-delete-task'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Says what happened and offers to take it back.
  ///
  /// Nothing is held back while the offer stands — the write has already
  /// happened and the list has already moved — because undo here is another
  /// write rather than a delayed commit, exactly as it is for a completion
  /// (ADR 0004).
  static void _offerUndo(
    ScaffoldMessengerState messenger,
    String message,
    VoidCallback undo,
  ) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: taskActionUndoWindow,
          action: SnackBarAction(label: 'Undo', onPressed: undo),
        ),
      );
  }
}

/// A chip marking a task that has been pushed out, so it is not mistaken for
/// one that is merely upcoming.
class SnoozedChip extends StatelessWidget {
  const SnoozedChip({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      avatar: Icon(
        Icons.snooze,
        size: 16,
        color: theme.colorScheme.onSecondaryContainer,
      ),
      label: const Text('Snoozed'),
      labelStyle: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSecondaryContainer,
      ),
      backgroundColor: theme.colorScheme.secondaryContainer,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );
  }
}

sealed class _Choice {
  const _Choice();
}

final class _Snooze extends _Choice {
  const _Snooze(this.option);

  final SnoozeOption option;
}

final class _CancelSnooze extends _Choice {
  const _CancelSnooze();
}

final class _Archive extends _Choice {
  const _Archive();
}

final class _Restore extends _Choice {
  const _Restore();
}

final class _Delete extends _Choice {
  const _Delete();
}
