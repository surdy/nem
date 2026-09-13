import '../data/digest_settings_repository.dart';
import '../data/task_repository.dart';
import '../domain/digest_schedule.dart';
import 'digest_notifier.dart';

/// Puts the digest's pending notifications in step with the tasks.
///
/// The interesting part is not here — it is [planDigests], which is pure. This
/// only gathers the inputs, applies the plan, and reports what happened.
class DigestScheduler {
  DigestScheduler({
    required this.notifier,
    required this.settings,
    required this.tasks,
    this.clock = DateTime.now,
  });

  final DigestNotifier notifier;
  final DigestSettingsRepository settings;
  final TaskRepository tasks;

  /// The clock, so a test can pin the window without waiting for a day to
  /// pass.
  final DateTime Function() clock;

  /// Recomputes the window and replaces whatever the digest had pending.
  ///
  /// Called on launch and on every foreground. It is idempotent: a plan is the
  /// complete set of digest notifications that should exist, so applying the
  /// same one twice leaves the same notifications pending.
  ///
  /// The digest's own pending notifications are cleared *after* the budget is
  /// read, so its slots are counted as available to it rather than as
  /// competition for itself.
  Future<DigestPlan> refresh() async {
    final current = await settings.read();
    final slots = digestSlots(pendingIds: await notifier.pendingIds());
    final plan = planDigests(
      settings: current,
      tasks: await tasks.allTasks(),
      now: clock(),
      slots: slots,
    );

    await notifier.cancelDigests();
    for (final digest in plan.entries) {
      await notifier.schedule(digest);
    }
    return plan;
  }

  /// Clears the digest without touching the stored settings — used when the
  /// digest is switched off.
  Future<void> clear() => notifier.cancelDigests();
}
