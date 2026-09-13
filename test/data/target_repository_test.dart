import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';

void main() {
  late NemDatabase db;
  late TargetRepository targets;
  late TaskRepository tasks;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    targets = TargetRepository(db);
    tasks = TaskRepository(db);
  });

  tearDown(() => db.close());

  test('creates a target with a name and a description', () async {
    final target = await targets.createTarget(
      name: '  The boiler  ',
      description: '  In the airing cupboard  ',
      now: DateTime(2026, 3, 1),
    );

    expect(target.name, 'The boiler');
    expect(target.description, 'In the airing cupboard');
    expect(target.createdAt, DateTime(2026, 3, 1));

    final stored = (await targets.allTargets()).single;
    expect(stored.id, target.id);
    expect(stored.name, 'The boiler');
  });

  test('a blank description is stored as null', () async {
    final target = await targets.createTarget(
      name: 'The car',
      description: '  ',
    );
    expect(target.description, isNull);
    expect((await targets.allTargets()).single.description, isNull);
  });

  test('targets are listed alphabetically', () async {
    await targets.createTarget(name: 'The front door');
    await targets.createTarget(name: 'The boiler');

    final listed = await targets.watchTargets().first;
    expect(listed.map((t) => t.name), ['The boiler', 'The front door']);
  });

  test('renames a target', () async {
    final target = await targets.createTarget(
      name: 'Boiler',
      description: 'Airing cupboard',
      now: DateTime(2026, 3, 1),
    );

    final renamed = await targets.updateTarget(
      id: target.id,
      name: 'The boiler',
      description: 'Upstairs landing',
      now: DateTime(2026, 3, 2),
    );

    expect(renamed?.name, 'The boiler');
    expect(renamed?.description, 'Upstairs landing');
    expect(renamed?.createdAt, DateTime(2026, 3, 1));
    expect(renamed?.updatedAt, DateTime(2026, 3, 2));
  });

  test(
    'a soft-deleted target is gone from reads but kept in the table',
    () async {
      final target = await targets.createTarget(name: 'The boiler');
      await targets.softDeleteTarget(target.id, now: DateTime(2026, 3, 3));

      expect(await targets.allTargets(), isEmpty);
      expect(await targets.watchTargets().first, isEmpty);
      expect(await targets.findTarget(target.id), isNull);
      expect(await targets.watchTarget(target.id).first, isNull);

      // The row survives as a tombstone, so that once sync lands the delete beats
      // a stale update rather than losing to one (PLAN.md — Sync).
      final row = await db.select(db.targets).getSingle();
      expect(row.id, target.id);
      expect(row.deletedAt, DateTime(2026, 3, 3));
    },
  );

  test('a deleted target cannot be renamed back into existence', () async {
    final target = await targets.createTarget(name: 'The boiler');
    await targets.softDeleteTarget(target.id);

    expect(
      await targets.updateTarget(id: target.id, name: 'The boiler again'),
      isNull,
    );
    expect(await targets.allTargets(), isEmpty);
    expect((await db.select(db.targets).getSingle()).name, 'The boiler');
  });

  test('soft-deleting a target leaves its tasks intact and unassigned', () async {
    final target = await targets.createTarget(name: 'The boiler');
    final task = await tasks.createFloatingTask(
      title: 'Service the boiler',
      targetId: target.id,
      intervalN: 1,
      intervalUnit: IntervalUnit.year,
      startDate: DateTime(2026, 2, 1),
      now: DateTime(2026, 2, 1),
    );

    await targets.softDeleteTarget(target.id, now: DateTime(2026, 3, 3));

    final survivor = (await tasks.allTasks()).single;
    expect(survivor.id, task.id);
    expect(survivor.title, 'Service the boiler');
    expect(survivor.targetId, isNull, reason: 'the task is unassigned');
    expect(
      survivor.dueDate,
      DateTime(2027, 2, 1),
      reason: 'its schedule is untouched',
    );

    // It still appears on the due list — deleting the boiler is not deleting the
    // work that was done on it.
    expect((await tasks.watchDueList().first).map((t) => t.id), [task.id]);

    // The unassignment is a change sync can see rather than a silent local edit.
    final row = await db.select(db.tasks).getSingle();
    expect(row.deletedAt, isNull);
    expect(row.updatedAt, DateTime(2026, 3, 3));
  });

  test(
    'deleting one target does not unassign another target\'s tasks',
    () async {
      final boiler = await targets.createTarget(name: 'The boiler');
      final car = await targets.createTarget(name: 'The car');
      await tasks.createFloatingTask(
        title: 'Service the boiler',
        targetId: boiler.id,
        intervalN: 1,
        intervalUnit: IntervalUnit.year,
        startDate: DateTime(2026, 2, 1),
      );
      await tasks.createFloatingTask(
        title: 'Check the tyre pressures',
        targetId: car.id,
        intervalN: 1,
        intervalUnit: IntervalUnit.month,
        startDate: DateTime(2026, 2, 1),
      );

      await targets.softDeleteTarget(boiler.id);

      final remaining = await tasks.watchTasksForTarget(car.id).first;
      expect(remaining.map((t) => t.title), ['Check the tyre pressures']);
      expect(await tasks.watchTasksForTarget(boiler.id).first, isEmpty);
    },
  );
}
