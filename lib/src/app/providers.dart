import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/task_repository.dart';
import '../domain/due_list.dart';
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

/// The current moment, overridable in tests.
final nowProvider = Provider<DateTime>((ref) => DateTime.now());
