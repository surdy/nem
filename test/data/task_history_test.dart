import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/completion_history.dart';
import 'package:nem/src/domain/interval_unit.dart';

/// History over the real log, through the repository.
///
/// The point of most of this is the negative one: the derived columns are
/// poisoned on purpose, and the history has to come out the same. `due_date`
/// and `last_completed_at` are sort caches (ADR 0004) — a history that read
/// them would agree with a stale cache instead of exposing it.
void main() {
  late NemDatabase db;
  late TaskRepository repository;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  /// A task due every 7 days from 1 June 2026.
  Future<String> weeklyTaskId() async {
    final task = await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 7,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  /// Writes nonsense into the two derived columns, as a sync pull or a
  /// timezone change could leave behind before the next recomputation.
  Future<void> poisonCaches(String taskId) async {
    await (db.update(db.tasks)..where((t) => t.id.equals(taskId))).write(
      TasksCompanion(
        dueDate: Value(DateTime(1999, 1, 1)),
        lastCompletedAt: Value(DateTime(1999, 1, 1)),
      ),
    );
  }

  Future<TaskHistory> historyOf(String taskId, DateTime now) async {
    final task = await repository.watchTask(taskId).first;
    return historyFor(
      task: task!,
      completions: await repository.completionsFor(taskId),
      now: now,
    );
  }

  test('history is built from the log, not from the derived caches', () async {
    final taskId = await weeklyTaskId();
    for (final at in [
      DateTime(2026, 6, 8, 9),
      DateTime(2026, 6, 15, 9),
      DateTime(2026, 7, 8, 9),
    ]) {
      await repository.recordCompletion(taskId, completedAt: at, now: at);
    }
    await poisonCaches(taskId);

    final history = await historyOf(taskId, DateTime(2026, 7, 10, 12));

    expect(history.entries.map((e) => e.completedAt), [
      DateTime(2026, 7, 8, 9),
      DateTime(2026, 6, 15, 9),
      DateTime(2026, 6, 8, 9),
    ]);
    // The 23-day gap is the missed fortnight ADR 0007 never showed as rows.
    expect(history.entries.map((e) => e.gapDays), [23, 7, null]);
    expect(history.entries.first.lateLabel, '16 days late');
    // 8 June is 32 days before the pinned now, so it falls out of the 30-day
    // window and stays in the 90-day one.
    expect(history.summaries.map((s) => s.completions), [2, 3]);

    // The stale column is still on disk, and the history ignored it.
    final row = await db.select(db.tasks).getSingle();
    expect(row.lastCompletedAt, DateTime(1999, 1, 1));
  });

  test('the task the history is read against reports the log\'s last '
      'completion, not the cached one', () async {
    final taskId = await weeklyTaskId();
    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 6, 8, 9),
      now: DateTime(2026, 6, 8, 9),
    );
    await poisonCaches(taskId);

    final task = await repository.watchTask(taskId).first;
    expect(task!.lastCompletedAt, DateTime(2026, 6, 8, 9));
    expect(task.dueDate, DateTime(2026, 6, 15, 9));
  });

  test('an undone completion leaves no trace in the history', () async {
    final taskId = await weeklyTaskId();
    final kept = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 6, 8, 9),
      now: DateTime(2026, 6, 8, 9),
    );
    final undone = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 6, 15, 9),
      now: DateTime(2026, 6, 15, 9),
    );
    await repository.undoCompletion(undone, now: DateTime(2026, 6, 15, 10));

    final history = await historyOf(taskId, DateTime(2026, 6, 16, 12));

    expect(history.entries.single.completion.id, kept.id);
    expect(history.summaries.first.completions, 1);
  });

  test(
    'a correction shows the replacement, not the row it retracted',
    () async {
      final taskId = await weeklyTaskId();
      final original = await repository.recordCompletion(
        taskId,
        completedAt: DateTime(2026, 6, 15, 9),
        now: DateTime(2026, 6, 15, 9),
      );
      final corrected = await repository.correctCompletion(
        original,
        completedAt: DateTime(2026, 6, 10, 9),
        now: DateTime(2026, 6, 15, 10),
      );

      final history = await historyOf(taskId, DateTime(2026, 6, 16, 12));

      // Both rows are still on disk; only the live one is history.
      expect(await db.select(db.completions).get(), hasLength(2));
      expect(history.entries.single.completion.id, corrected.id);
      expect(history.entries.single.completedAt, DateTime(2026, 6, 10, 9));
      expect(history.summaries.first.completions, 1);
    },
  );

  test('watchCompletionsFor emits the log as it changes', () async {
    final taskId = await weeklyTaskId();
    final emissions = repository.watchCompletionsFor(taskId);

    expect(await emissions.first, isEmpty);

    final completion = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 6, 8, 9),
      now: DateTime(2026, 6, 8, 9),
    );
    expect((await emissions.first).single.id, completion.id);

    await repository.undoCompletion(completion, now: DateTime(2026, 6, 8, 10));
    expect(await emissions.first, isEmpty);
  });

  test('watchCompletionsFor keeps one task\'s log to itself', () async {
    final mine = await weeklyTaskId();
    final theirs = await weeklyTaskId();
    await repository.recordCompletion(
      theirs,
      completedAt: DateTime(2026, 6, 8, 9),
      now: DateTime(2026, 6, 8, 9),
    );

    expect(await repository.watchCompletionsFor(mine).first, isEmpty);
    expect(await repository.watchCompletionsFor(theirs).first, hasLength(1));
  });

  test('watchTask emits null for a task that is not there', () async {
    expect(await repository.watchTask('no-such-task').first, isNull);
  });
}
