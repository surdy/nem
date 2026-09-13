import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/database.dart';
import '../data/target_repository.dart';
import '../data/task_repository.dart';
import '../domain/due_list.dart';
import '../domain/target.dart';
import '../domain/task.dart';

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

/// The current moment, overridable in tests.
final nowProvider = Provider<DateTime>((ref) => DateTime.now());

/// The IANA zone id a newly authored fixed schedule is anchored in (ADR 0010).
///
/// Reads `tz.local`, which `initialiseTimeZones` points at the device's zone on
/// launch. It is a provider so a test can pin it, and so the zone is read once
/// at authoring time rather than every time a due date is computed — a task
/// created in London stays a London task after the phone lands in Tokyo.
final zoneIdProvider = Provider<String>((ref) => tz.local.name);
