import '../data/task_repository.dart';
import '../domain/completion.dart';
import '../notifications/reminder_scheduler.dart';

/// Recording a completion, and everything that has to happen because of it.
///
/// A completion is the one user action that both moves a due date and has to
/// reach the OS. A task that has just been done is no longer due, so its
/// pending reminders are no longer true and have to be taken back
/// (CONTEXT.md — "Reminder"); undoing the completion puts the task back on the
/// due list, so they have to come back.
///
/// This exists so that is structural rather than remembered. There are four
/// places in the UI that complete or un-complete a task — the due list tile,
/// the scan's single-task path, and both directions of the scan sheet — and a
/// fifth is one ticket away. All of them go through here, so none of them can
/// leave a reminder pending for work that is already done.
///
/// The digest deliberately does not refresh here. It is re-topped on
/// foreground, its window is a count rather than a per-task statement, and the
/// two budgets are disjoint (14 of 64 for the digest, 40 for reminders), so a
/// reminder re-plan can never take a slot the digest was holding.
class TaskCompletions {
  const TaskCompletions({required this.tasks, required this.reminders});

  final TaskRepository tasks;
  final ReminderScheduler reminders;

  /// Records that a task was performed, then re-plans the reminders.
  ///
  /// Returns the completion, which is what [undo] needs to take it back.
  Future<Completion> record(
    String taskId, {
    CompletionSource source = CompletionSource.manual,
  }) async {
    final completion = await tasks.recordCompletion(taskId, source: source);
    await reminders.refresh();
    return completion;
  }

  /// Takes a completion back, then re-plans the reminders.
  Future<void> undo(Completion completion) async {
    await tasks.undoCompletion(completion);
    await reminders.refresh();
  }
}
