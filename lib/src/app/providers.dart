import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/database.dart';
import '../data/digest_settings_repository.dart';
import '../data/target_repository.dart';
import '../data/task_repository.dart';
import '../domain/completion.dart';
import '../domain/completion_history.dart';
import '../domain/digest.dart';
import '../domain/due_list.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import '../notifications/digest_notifier.dart';
import '../notifications/digest_scheduler.dart';
import '../notifications/local_digest_notifier.dart';
import 'app.dart';

/// Manual providers throughout — Riverpod 3 recommends `@riverpod` codegen only
/// where build_runner is already earning its keep elsewhere (PLAN.md,
/// assumption 2).

/// The local SQLite database, which is the source of truth (ADR 0001).
final databaseProvider = Provider<NemDatabase>((ref) {
  final db = NemDatabase();
  ref.onDispose(db.close);
  return db;
});

final taskRepositoryProvider = Provider<TaskRepository>(
  (ref) => TaskRepository(ref.watch(databaseProvider)),
);

/// Every live task, soonest due first.
final dueListProvider = StreamProvider<List<Task>>(
  (ref) => ref.watch(taskRepositoryProvider).watchDueList(),
);

/// The due list grouped Overdue / Today / Soon.
///
/// Reads the clock through [nowProvider] so the grouping can be pinned in
/// tests.
final dueSectionsProvider = Provider<AsyncValue<List<DueSection>>>((ref) {
  final now = ref.watch(nowProvider);
  return ref
      .watch(dueListProvider)
      .whenData((tasks) => groupByDueStatus(tasks, now));
});

final targetRepositoryProvider = Provider<TargetRepository>(
  (ref) => TargetRepository(ref.watch(databaseProvider)),
);

/// Every live target, alphabetically.
final targetListProvider = StreamProvider<List<Target>>(
  (ref) => ref.watch(targetRepositoryProvider).watchTargets(),
);

/// One target, or null once it has been deleted — which is how the detail
/// screen learns to close itself.
final targetProvider = StreamProvider.family<Target?, String>(
  (ref, id) => ref.watch(targetRepositoryProvider).watchTarget(id),
);

/// The tasks at one target, soonest due first.
final targetTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, targetId) =>
      ref.watch(taskRepositoryProvider).watchTasksForTarget(targetId),
);

/// One task, live, or null once it is gone.
final taskProvider = StreamProvider.family<Task?, String>(
  (ref, taskId) => ref.watch(taskRepositoryProvider).watchTask(taskId),
);

/// A task's surviving completions, most recent work first.
///
/// The completion log itself — nothing derived, nothing cached (ADR 0004).
final completionsProvider = StreamProvider.family<List<Completion>, String>(
  (ref, taskId) =>
      ref.watch(taskRepositoryProvider).watchCompletionsFor(taskId),
);

/// A task's history: its completions, the gap between each consecutive pair,
/// and the trailing-window counts.
final taskHistoryProvider = Provider.family<AsyncValue<TaskHistory>, String>((
  ref,
  taskId,
) {
  final now = ref.watch(nowProvider);
  final task = ref.watch(taskProvider(taskId));
  final completions = ref.watch(completionsProvider(taskId));
  return task.when(
    loading: () => const AsyncValue<TaskHistory>.loading(),
    error: AsyncValue<TaskHistory>.error,
    data: (task) => task == null
        ? const AsyncValue.data(TaskHistory.empty)
        : completions.whenData(
            (completions) =>
                historyFor(task: task, completions: completions, now: now),
          ),
  );
});

/// The current moment, overridable in tests.
final nowProvider = Provider<DateTime>((ref) => DateTime.now());

/// The IANA zone id a newly authored fixed schedule is anchored in (ADR 0010).
///
/// Reads `tz.local`, which `initialiseTimeZones` points at the device's zone on
/// launch. It is a provider so a test can pin it, and so the zone is read once
/// at authoring time rather than every time a due date is computed — a task
/// created in London stays a London task after the phone lands in Tokyo.
final zoneIdProvider = Provider<String>((ref) => tz.local.name);

final digestSettingsRepositoryProvider = Provider<DigestSettingsRepository>(
  (ref) => DigestSettingsRepository(ref.watch(databaseProvider)),
);

/// The one place the notification plugin is reached from. Overridden with a
/// fake in tests, which is the whole point of the seam.
final digestNotifierProvider = Provider<DigestNotifier>(
  (ref) => LocalDigestNotifier(onTapped: (_) => showDueList()),
);

final digestSchedulerProvider = Provider<DigestScheduler>(
  (ref) => DigestScheduler(
    notifier: ref.watch(digestNotifierProvider),
    settings: ref.watch(digestSettingsRepositoryProvider),
    tasks: ref.watch(taskRepositoryProvider),
  ),
);

/// The stored digest configuration. Invalidated after every write so the
/// settings screen and the scheduler read the same thing.
final digestSettingsProvider = FutureProvider<DigestSettings>(
  (ref) => ref.watch(digestSettingsRepositoryProvider).read(),
);

/// What the OS currently allows, read without prompting.
final digestPermissionProvider = FutureProvider<NotificationPermission>(
  (ref) => ref.watch(digestNotifierProvider).permission(),
);
