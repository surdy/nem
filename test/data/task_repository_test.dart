import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/task.dart';

void main() {
  late NemDatabase db;
  late TaskRepository repository;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  test('the schema is created at version 2', () async {
    expect(db.schemaVersion, 2);
    expect(await repository.allTasks(), isEmpty);
  });

  test('creates a floating task and derives its due date', () async {
    final task = await repository.createFloatingTask(
      title: 'Replace the water filter',
      notes: '  under the sink  ',
      intervalN: 3,
      intervalUnit: IntervalUnit.month,
      startDate: DateTime(2026, 1, 15),
    );

    expect(task.scheduleMode, ScheduleMode.floating);
    expect(task.notes, 'under the sink');
    expect(task.dueDate, DateTime(2026, 4, 15));

    final stored = (await repository.allTasks()).single;
    expect(stored.id, task.id);
    expect(stored.title, 'Replace the water filter');
    expect(stored.floatingSchedule?.intervalN, 3);
    expect(stored.floatingSchedule?.intervalUnit, IntervalUnit.month);
    expect(stored.lastCompletedAt, isNull);
    expect(stored.rrule, isNull);
    expect(stored.dueDate, DateTime(2026, 4, 15));
  });

  test('blank notes are stored as null', () async {
    final task = await repository.createFloatingTask(
      title: 'Bleed the radiators',
      notes: '   ',
      intervalN: 1,
      intervalUnit: IntervalUnit.year,
      startDate: DateTime(2026, 9, 1),
    );
    expect(task.notes, isNull);
    expect((await repository.allTasks()).single.notes, isNull);
  });

  test('ids are unique', () async {
    final ids = <String>{};
    for (var i = 0; i < 25; i++) {
      final task = await repository.createFloatingTask(
        title: 'Task $i',
        intervalN: 1,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 1, 1),
      );
      ids.add(task.id);
    }
    expect(ids, hasLength(25));
  });

  test('the due list is ordered by due date', () async {
    await repository.createFloatingTask(
      title: 'Later',
      intervalN: 1,
      intervalUnit: IntervalUnit.year,
      startDate: DateTime(2026, 1, 1),
    );
    await repository.createFloatingTask(
      title: 'Sooner',
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 1, 1),
    );

    final tasks = await repository.watchDueList().first;
    expect(tasks.map((t) => t.title), ['Sooner', 'Later']);
  });

  test(
    'recomputeDerivedState repairs a stale cache without touching truth',
    () async {
      final task = await repository.createFloatingTask(
        title: 'Service the boiler',
        intervalN: 1,
        intervalUnit: IntervalUnit.year,
        startDate: DateTime(2026, 2, 1),
      );

      // Corrupt the denormalised cache the way a bad sync pull might.
      await db.customStatement('UPDATE tasks SET due_date = 0 WHERE id = ?', [
        task.id,
      ]);

      // The derived value is still correct even with the cache wrong (ADR 0004).
      expect(
        (await repository.allTasks()).single.dueDate,
        DateTime(2027, 2, 1),
      );

      expect(await repository.recomputeDerivedState(), 1);
      final row = await db.select(db.tasks).getSingle();
      expect(row.dueDate, DateTime(2027, 2, 1));

      // A second run has nothing left to fix.
      expect(await repository.recomputeDerivedState(), 0);
    },
  );
}
