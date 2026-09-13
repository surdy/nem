import '../data/task_repository.dart';
import '../domain/reminder_schedule.dart';
import 'reminder_notifier.dart';

/// Puts the reminders' pending notifications in step with the tasks
/// (CONTEXT.md — "Reminder").
///
/// The interesting part is not here — it is [planReminders], which is pure.
/// This only gathers the inputs, applies the plan, and reports what happened.
class ReminderScheduler {
  ReminderScheduler({
    required this.notifier,
    required this.tasks,
    this.clock = DateTime.now,
  });

  final ReminderNotifier notifier;
  final TaskRepository tasks;

  /// The clock, so a test can pin the window without waiting for a day to
  /// pass.
  final DateTime Function() clock;

  /// Recomputes the window and replaces whatever the reminders had pending.
  ///
  /// Called on launch, on every foreground, whenever a reminder is set or
  /// cleared, and after every completion — a completion is what makes a task
  /// stop being due, so it is what takes that task's reminders back.
  ///
  /// Idempotent: a plan is the complete set of reminder notifications that
  /// should exist, so applying the same one twice leaves the same
  /// notifications pending.
  ///
  /// The reminders' own pending notifications are cleared *after* the budget
  /// is read, so their slots are counted as available to them rather than as
  /// competition for themselves — and the digest's are counted as taken, which
  /// is the half of the arrangement that keeps the two from colliding.
  Future<ReminderPlan> refresh() async {
    final slots = reminderSlots(pendingIds: await notifier.pendingIds());
    final plan = planReminders(
      tasks: await tasks.allTasks(),
      now: clock(),
      slots: slots,
    );

    await notifier.cancelReminders();
    for (final reminder in plan.entries) {
      await notifier.schedule(reminder);
    }
    return plan;
  }

  /// Takes back every pending reminder without touching any task's stored
  /// reminder time.
  Future<void> clear() => notifier.cancelReminders();
}
