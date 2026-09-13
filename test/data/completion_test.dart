import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/completion.dart';
import 'package:nem/src/domain/interval_unit.dart';

/// The completion log and the state derived from it (ADR 0004).
///
/// The dates here deliberately straddle the northern spring-forward (8 March
/// 2026 in America/New_York): a due date that keeps its wall-clock time is the
/// evidence that calendar arithmetic, not `Duration(days:)`, moved it.
void main() {
  late NemDatabase db;
  late TaskRepository repository;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  Future<TaskRow> storedRow() => db.select(db.tasks).getSingle();

  /// A task due 31 March 2026, thirty days after its start date.
  Future<String> filterTaskId() async {
    final task = await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 3, 1, 9),
    );
    expect(task.dueDate, DateTime(2026, 3, 31, 9));
    return task.id;
  }

  test('completing a task moves its due date on', () async {
    final taskId = await filterTaskId();

    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 5, 9),
    );

    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, DateTime(2026, 3, 5, 9));
    // Thirty calendar days on, same wall clock, across the spring-forward.
    expect(task.dueDate, DateTime(2026, 4, 4, 9));

    // The caches were brought along with it.
    final row = await storedRow();
    expect(row.lastCompletedAt, DateTime(2026, 3, 5, 9));
    expect(row.dueDate, DateTime(2026, 4, 4, 9));
  });

  test('a completion is recorded with source manual by default', () async {
    final taskId = await filterTaskId();

    final completion = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      note: '  cartridge was black  ',
      now: DateTime(2026, 3, 5, 9, 30),
    );

    expect(completion.source, CompletionSource.manual);
    expect(completion.note, 'cartridge was black');
    expect(completion.deviceId, await repository.deviceId());
    // When the work happened is not when the row was written.
    expect(completion.completedAt, DateTime(2026, 3, 5, 9));
    expect(completion.createdAt, DateTime(2026, 3, 5, 9, 30));
    expect(completion.isTombstoned, isFalse);

    expect(await repository.completionsFor(taskId), hasLength(1));
  });

  test('completing a floating task early re-anchors it from the '
      'completion date', () async {
    final taskId = await filterTaskId();

    // Due 31 March; done on the 5th, three weeks early.
    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 5, 9),
    );

    // The next one is measured from the completion, not from the due date it
    // replaced — 4 April rather than 30 April (CONTEXT.md — "Floating
    // schedule").
    expect((await repository.allTasks()).single.dueDate, DateTime(2026, 4, 4, 9));
  });

  test('undo tombstones the completion and restores the previous '
      'state', () async {
    final taskId = await filterTaskId();

    final completion = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 5, 9),
    );
    await repository.undoCompletion(
      completion,
      now: DateTime(2026, 3, 5, 9, 0, 3),
    );

    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, isNull);
    expect(task.dueDate, DateTime(2026, 3, 31, 9));

    final row = await storedRow();
    expect(row.lastCompletedAt, isNull);
    expect(row.dueDate, DateTime(2026, 3, 31, 9));

    // The event itself is still on disk, tombstoned rather than erased.
    final stored = await db.select(db.completions).getSingle();
    expect(stored.deletedAt, DateTime(2026, 3, 5, 9, 0, 3));
    expect(stored.completedAt, DateTime(2026, 3, 5, 9));
    expect(await repository.completionsFor(taskId), isEmpty);
  });

  test('undo falls back to the completion before it', () async {
    final taskId = await filterTaskId();

    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 1, 4, 9),
      now: DateTime(2026, 1, 4, 9),
    );
    final second = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 5, 9),
    );
    expect((await repository.allTasks()).single.dueDate, DateTime(2026, 4, 4, 9));

    await repository.undoCompletion(second, now: DateTime(2026, 3, 5, 9, 0, 3));

    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, DateTime(2026, 1, 4, 9));
    expect(task.dueDate, DateTime(2026, 2, 3, 9));
    expect(await repository.completionsFor(taskId), hasLength(1));
  });

  test('a completion recorded out of order does not move the state '
      'backwards', () async {
    final taskId = await filterTaskId();

    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 20, 9),
      now: DateTime(2026, 3, 20, 9),
    );
    // Arrives late — recorded now, but the work happened a fortnight ago. This
    // is what a sync pull from the other device looks like.
    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 21, 9),
    );

    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, DateTime(2026, 3, 20, 9));
    expect(task.dueDate, DateTime(2026, 4, 19, 9));
    expect(await repository.completionsFor(taskId), hasLength(2));

    // And a full recomputation agrees, from the log alone.
    expect(await repository.recomputeDerivedState(), 0);
  });

  test('recomputation is idempotent and repairs a stale cache', () async {
    final taskId = await filterTaskId();
    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 5, 9),
    );

    // Nothing to do straight after a write.
    expect(await repository.recomputeDerivedState(), 0);
    expect(await repository.recomputeDerivedState(), 0);

    // Corrupt both caches the way a bad sync pull or a stopped clock might.
    await db.customStatement(
      'UPDATE tasks SET due_date = 0, last_completed_at = 0',
    );

    // The derived values are right even with the caches wrong (ADR 0004).
    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, DateTime(2026, 3, 5, 9));
    expect(task.dueDate, DateTime(2026, 4, 4, 9));

    expect(await repository.recomputeDerivedState(), 1);
    final row = await storedRow();
    expect(row.lastCompletedAt, DateTime(2026, 3, 5, 9));
    expect(row.dueDate, DateTime(2026, 4, 4, 9));

    // A second run has nothing left to fix.
    expect(await repository.recomputeDerivedState(), 0);
  });

  test('a correction tombstones the original and appends a '
      'replacement', () async {
    final taskId = await filterTaskId();

    final original = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      note: 'today',
      now: DateTime(2026, 3, 5, 9),
    );
    final replacement = await repository.correctCompletion(
      original,
      completedAt: DateTime(2026, 3, 3, 9),
      note: 'actually Tuesday',
      now: DateTime(2026, 3, 5, 9, 10),
    );

    expect(replacement.id, isNot(original.id));
    expect(replacement.source, CompletionSource.manual);
    expect(replacement.note, 'actually Tuesday');

    // Two rows on disk, one of them tombstoned; one surviving completion.
    expect(await db.select(db.completions).get(), hasLength(2));
    final live = await repository.completionsFor(taskId);
    expect(live.single.id, replacement.id);

    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, DateTime(2026, 3, 3, 9));
    expect(task.dueDate, DateTime(2026, 4, 2, 9));
  });

  test('the due list reflects a completion', () async {
    final taskId = await filterTaskId();
    expect(
      (await repository.watchDueList().first).single.dueDate,
      DateTime(2026, 3, 31, 9),
    );

    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 3, 5, 9),
      now: DateTime(2026, 3, 5, 9),
    );

    expect(
      (await repository.watchDueList().first).single.dueDate,
      DateTime(2026, 4, 4, 9),
    );
  });

  test('the device id is minted once and reused', () async {
    final first = await repository.deviceId();
    expect(first, isNotEmpty);
    expect(await repository.deviceId(), first);

    // A second repository over the same database finds the stored one rather
    // than minting its own.
    expect(await TaskRepository(db).deviceId(), first);
  });

  test('a completion cannot reference a task that does not exist', () async {
    // The foreign key is enforced because `beforeOpen` turns it on.
    await expectLater(
      repository.recordCompletion('no-such-task'),
      throwsA(isA<Exception>()),
    );
  });
}
