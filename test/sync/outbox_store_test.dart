import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/binding_repository.dart';
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

    test('recording a completion queues the completion and not the '
        'task', () async {
      final id = await createTask();
      await outbox.remove('tasks', id);

      final completion = await tasks.recordCompletion(
        id,
        now: DateTime(2026, 6, 2, 9),
      );
      // The completion is a row of its own and syncs as one (#12). What must
      // not happen is the *task* being pushed too: `due_date` and
      // `last_completed_at` are derived caches and the other device recomputes
      // them from its own copy of the log (ADR 0004).
      expect(
        [
          for (final entry in await outbox.pending())
            '${entry.table}/${entry.rowId}',
        ],
        ['completions/${completion.id}'],
      );

      // Taking it back queues the same row again — the tombstone is the only
      // thing that ever moves on a completion, and it has to travel.
      await outbox.remove('completions', completion.id);
      await tasks.undoCompletion(completion, now: DateTime(2026, 6, 2, 10));
      expect(
        [
          for (final entry in await outbox.pending())
            '${entry.table}/${entry.rowId}',
        ],
        ['completions/${completion.id}'],
      );
    });

    test('correcting a completion queues both the tombstone and its '
        'replacement', () async {
      final id = await createTask();
      final original = await tasks.recordCompletion(
        id,
        completedAt: DateTime(2026, 6, 2, 9),
        now: DateTime(2026, 6, 2, 9),
      );
      await outbox.remove('tasks', id);
      await outbox.remove('completions', original.id);

      // A correction is a tombstone plus a fresh row, never an edit (ADR 0004),
      // so it is two rows to push and the far device has to see both.
      final replacement = await tasks.correctCompletion(
        original,
        completedAt: DateTime(2026, 5, 31, 9),
        now: DateTime(2026, 6, 3, 9),
      );
      expect(
        {
          for (final entry in await outbox.pending())
            '${entry.table}/${entry.rowId}',
        },
        {'completions/${original.id}', 'completions/${replacement.id}'},
      );
    });

    test('recomputing derived state does not', () async {
      final id = await createTask();
      final completion = await tasks.recordCompletion(
        id,
        now: DateTime(2026, 6, 2, 9),
      );
      await outbox.remove('tasks', id);
      await outbox.remove('completions', completion.id);

      await tasks.recomputeDerivedState();
      expect(await outbox.count(), 0);
    });

    test('provisioning a code queues the binding', () async {
      final targets = TargetRepository(db);
      final bindings = BindingRepository(db);
      final target = await targets.createTarget(
        name: 'The boiler',
        now: DateTime(2026, 6, 1, 9),
      );
      await outbox.remove('targets', target.id);

      // A label printed here has to resolve on the other device (#12).
      final label = await bindings.generateLabel(
        target.id,
        now: DateTime(2026, 6, 2, 9),
      );
      expect(
        [
          for (final entry in await outbox.pending())
            '${entry.table}/${entry.rowId}',
        ],
        ['bindings/${label.id}'],
      );

      // And unbinding it queues the same row, carrying the tombstone.
      await outbox.remove('bindings', label.id);
      await bindings.unbind(label.id, now: DateTime(2026, 6, 3, 9));
      expect(
        [
          for (final entry in await outbox.pending())
            '${entry.table}/${entry.rowId}',
        ],
        ['bindings/${label.id}'],
      );
    });

    test('creating and renaming a target queues it', () async {
      final targets = TargetRepository(db);
      final target = await targets.createTarget(
        name: 'The boiler',
        now: DateTime(2026, 6, 1, 9),
      );
      expect(
        [
          for (final entry in await outbox.pending())
            '${entry.table}/${entry.rowId}',
        ],
        ['targets/${target.id}'],
      );

      await outbox.remove('targets', target.id);
      await targets.updateTarget(
        id: target.id,
        name: 'The boiler cupboard',
        now: DateTime(2026, 6, 2, 9),
      );
      expect(await outbox.count(), 1);
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
      // The target's own tombstone goes up alongside it.
      expect(
        {
          for (final entry in await outbox.pending())
            '${entry.table}/${entry.rowId}',
        },
        {'tasks/${task.id}', 'targets/${target.id}'},
      );
    });
  });
}
