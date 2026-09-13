import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/reminder.dart';
import 'package:nem/src/sync/outbox_store.dart';

void main() {
  late NemDatabase db;
  late OutboxStore outbox;
  late TaskRepository tasks;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    outbox = OutboxStore(db);
    tasks = TaskRepository(db);
  });

  tearDown(() => db.close());

  Future<String> createTask({
    String title = 'Water the plants',
    DateTime? now,
  }) async => (await tasks.createFloatingTask(
    title: title,
    intervalN: 7,
    intervalUnit: IntervalUnit.day,
    startDate: DateTime(2026, 6, 1),
    now: now ?? DateTime(2026, 6, 1, 9),
  )).id;

  group('the queue itself', () {
    test('queueing the same row twice leaves one entry at the first '
        'moment', () async {
      await outbox.enqueue('tasks', 'task-1', now: DateTime(2026, 6, 1, 9));
      await outbox.enqueue('tasks', 'task-1', now: DateTime(2026, 6, 5, 9));

      final entries = await outbox.pending();
      expect(entries, hasLength(1));
      // The drain runs in this order, so a row that keeps being edited must not
      // keep moving to the back of the queue.
      expect(entries.single.enqueuedAt, DateTime(2026, 6, 1, 9));
    });

    test('entries come back oldest first', () async {
      await outbox.enqueue('tasks', 'c', now: DateTime(2026, 6, 3, 9));
      await outbox.enqueue('tasks', 'a', now: DateTime(2026, 6, 1, 9));
      await outbox.enqueue('tasks', 'b', now: DateTime(2026, 6, 2, 9));

      expect(
        [for (final entry in await outbox.pending()) entry.rowId],
        ['a', 'b', 'c'],
      );
    });

    test('failures accumulate on the entry', () async {
      await outbox.enqueue('tasks', 'task-1');
      await outbox.recordFailure('tasks', 'task-1', 'no route to host');
      await outbox.recordFailure('tasks', 'task-1', 'timed out');

      final entry = (await outbox.pending()).single;
      expect(entry.attempts, 2);
      expect(entry.lastError, 'timed out');
    });

    test('the count is watchable, so the screen can say how much is '
        'waiting', () async {
      expect(await outbox.watchCount().first, 0);
      await outbox.enqueue('tasks', 'task-1');
      expect(await outbox.watchCount().first, 1);
    });
  });

  group('what the repositories queue', () {
    test('creating a task', () async {
      final id = await createTask();
      expect([for (final entry in await outbox.pending()) entry.rowId], [id]);
    });

    test('snoozing and un-snoozing', () async {
      final id = await createTask();
      await outbox.remove('tasks', id);

      await tasks.snoozeTask(
        id,
        n: 2,
        unit: IntervalUnit.day,
        now: DateTime(2026, 6, 2, 9),
      );
      expect(await outbox.count(), 1);

      await outbox.remove('tasks', id);
      await tasks.cancelSnooze(id, now: DateTime(2026, 6, 3, 9));
      expect(await outbox.count(), 1);
    });

    test('archiving and restoring', () async {
      final id = await createTask();
      await outbox.remove('tasks', id);

      await tasks.archiveTask(id, now: DateTime(2026, 6, 2, 9));
      expect(await outbox.count(), 1);

      await outbox.remove('tasks', id);
      await tasks.restoreTask(id, now: DateTime(2026, 6, 3, 9));
      expect(await outbox.count(), 1);
    });

    test('setting and clearing a per-task reminder', () async {
      final id = await createTask();
      await outbox.remove('tasks', id);

      await tasks.setReminderTime(
        id,
        const ReminderTime(hour: 18, minute: 30),
        now: DateTime(2026, 6, 2, 9),
      );
      expect(await outbox.count(), 1);

      await outbox.remove('tasks', id);
      await tasks.setReminderTime(id, null, now: DateTime(2026, 6, 3, 9));
      expect(await outbox.count(), 1);
    });

    test('recording a completion does not, because it does not change what '
        'the task says', () async {
      final id = await createTask();
      await outbox.remove('tasks', id);

      final completion = await tasks.recordCompletion(
        id,
        now: DateTime(2026, 6, 2, 9),
      );
      // The completion itself is a row of its own and arrives in #12; what must
      // not happen is the *task* being pushed, because `due_date` and
      // `last_completed_at` are derived caches and the other device recomputes
      // them from the log (ADR 0004).
      expect(await outbox.count(), 0);

      await tasks.undoCompletion(completion, now: DateTime(2026, 6, 2, 10));
      expect(await outbox.count(), 0);
    });

    test('recomputing derived state does not', () async {
      final id = await createTask();
      await tasks.recordCompletion(id, now: DateTime(2026, 6, 2, 9));
      await outbox.remove('tasks', id);

      await tasks.recomputeDerivedState();
      expect(await outbox.count(), 0);
    });

    test('deleting a target queues the tasks it unassigns', () async {
      final targets = TargetRepository(db);
      final target = await targets.createTarget(name: 'The boiler');
      final task = await tasks.createFloatingTask(
        title: 'Bleed the radiators',
        targetId: target.id,
        intervalN: 1,
        intervalUnit: IntervalUnit.year,
        startDate: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 9),
      );
      await outbox.remove('tasks', task.id);

      await targets.softDeleteTarget(target.id, now: DateTime(2026, 6, 2, 9));

      // The unassignment bumps the task's `updated_at`, so unless the task is
      // pushed the other device keeps showing the work at a target that is
      // gone — and the next pull would hand the stale reference straight back.
      expect(
        [for (final entry in await outbox.pending()) entry.rowId],
        [task.id],
      );
    });
  });
}
