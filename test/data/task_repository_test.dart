import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/task.dart';
import 'package:timezone/data/latest.dart' as tz_data;

/// Tuesdays from 6 January 2026, in a zone that is UTC+0 that month — so the
/// completion instants below read the same in London as they do in UTC.
FixedSchedule tuesdays() => FixedSchedule.build(
  frequency: FixedFrequency.weekly,
  weekdays: {DateTime.tuesday},
  startDate: DateTime(2026, 1, 6),
  zoneId: 'Europe/London',
);

String date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}'
    '-${value.day.toString().padLeft(2, '0')}';

void main() {
  late NemDatabase db;
  late TaskRepository repository;

  // Fixed schedules resolve against the tz database (ADR 0010).
  setUpAll(tz_data.initializeTimeZones);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  test('the schema is created at version 4', () async {
    expect(db.schemaVersion, 4);
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
    expect(stored.targetId, isNull, reason: 'a target is optional');
  });

  test('a task can be created at a target', () async {
    final target = await TargetRepository(db).createTarget(name: 'The boiler');
    final task = await repository.createFloatingTask(
      title: 'Service the boiler',
      targetId: target.id,
      intervalN: 1,
      intervalUnit: IntervalUnit.year,
      startDate: DateTime(2026, 2, 1),
    );

    expect(task.targetId, target.id);
    expect((await repository.allTasks()).single.targetId, target.id);
  });

  test('the tasks at a target are ordered by due date', () async {
    final target = await TargetRepository(db).createTarget(name: 'The boiler');
    await repository.createFloatingTask(
      title: 'Later',
      targetId: target.id,
      intervalN: 1,
      intervalUnit: IntervalUnit.year,
      startDate: DateTime(2026, 1, 1),
    );
    await repository.createFloatingTask(
      title: 'Sooner',
      targetId: target.id,
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 1, 1),
    );
    await repository.createFloatingTask(
      title: 'Somewhere else',
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 1, 1),
    );

    final atTarget = await repository.watchTasksForTarget(target.id).first;
    expect(atTarget.map((t) => t.title), ['Sooner', 'Later']);
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

  group('fixed schedules', () {
    test(
      'stores the rule and derives the due date from the calendar',
      () async {
        final task = await repository.createFixedTask(
          title: 'Put the bins out',
          notes: '  green bin  ',
          schedule: tuesdays(),
        );

        expect(task.scheduleMode, ScheduleMode.fixed);
        expect(task.notes, 'green bin');
        expect(
          task.rrule,
          'DTSTART;TZID=Europe/London:20260106T000000\n'
          'RRULE:FREQ=WEEKLY;BYDAY=TU',
        );
        expect(date(task.dueDate!), '2026-01-06');

        final stored = (await repository.allTasks()).single;
        expect(stored.floatingSchedule, isNull);
        expect(stored.fixedSchedule?.zoneId, 'Europe/London');
        expect(stored.scheduleLabel, 'Every Tuesday');
        expect(date(stored.dueDate!), '2026-01-06');

        // The cache column agrees with the derived value, to the second.
        final row = await db.select(db.tasks).getSingle();
        expect(row.dueDate!.isAtSameMomentAs(stored.dueDate!), isTrue);
      },
    );

    test('three missed occurrences stay one row, and one due date', () async {
      await repository.createFixedTask(
        title: 'Put the bins out',
        schedule: tuesdays(),
      );

      // By Thursday 22 January the 6th, 13th and 20th have all gone by.
      final tasks = await repository.watchDueList().first;
      expect(tasks, hasLength(1));
      expect(date(tasks.single.dueDate!), '2026-01-06');
    });

    test('completing skips the intervening misses', () async {
      final task = await repository.createFixedTask(
        title: 'Put the bins out',
        schedule: tuesdays(),
      );

      await repository.recordCompletion(
        task.id,
        completedAt: DateTime.utc(2026, 1, 22, 10),
      );

      final completed = (await repository.allTasks()).single;
      expect(date(completed.dueDate!), '2026-01-27');

      // And the cache moved with it, so the due list sorts on the new date.
      final row = await db.select(db.tasks).getSingle();
      expect(row.dueDate!.isAtSameMomentAs(completed.dueDate!), isTrue);
    });

    test(
      'undo puts the due date back on the first missed occurrence',
      () async {
        final task = await repository.createFixedTask(
          title: 'Put the bins out',
          schedule: tuesdays(),
        );
        final completion = await repository.recordCompletion(
          task.id,
          completedAt: DateTime.utc(2026, 1, 22, 10),
        );
        await repository.undoCompletion(completion);

        expect(
          date((await repository.allTasks()).single.dueDate!),
          '2026-01-06',
        );
      },
    );

    test('recomputeDerivedState converges for a fixed task', () async {
      final task = await repository.createFixedTask(
        title: 'Put the bins out',
        schedule: tuesdays(),
      );
      await db.customStatement('UPDATE tasks SET due_date = 0 WHERE id = ?', [
        task.id,
      ]);

      expect(await repository.recomputeDerivedState(), 1);
      // A fixed due date is a TZDateTime and the column gives back a plain
      // DateTime; comparing them with `==` would report a change every time and
      // never settle.
      expect(await repository.recomputeDerivedState(), 0);
    });

    test(
      'a rule this build cannot read costs a due date, not the list',
      () async {
        final task = await repository.createFixedTask(
          title: 'Imported from somewhere',
          schedule: tuesdays(),
        );
        await db.customStatement(
          "UPDATE tasks SET rrule = 'RRULE:FREQ=NONSENSE' WHERE id = ?",
          [task.id],
        );

        final stored = (await repository.allTasks()).single;
        expect(stored.fixedSchedule, isNull);
        expect(stored.rrule, 'RRULE:FREQ=NONSENSE');
        expect(stored.dueDate, isNull);
        expect(await repository.watchDueList().first, hasLength(1));
      },
    );

    test('floating and fixed tasks share the list', () async {
      await repository.createFloatingTask(
        title: 'Replace the water filter',
        intervalN: 3,
        intervalUnit: IntervalUnit.month,
        startDate: DateTime(2026, 1, 15),
      );
      await repository.createFixedTask(
        title: 'Put the bins out',
        schedule: tuesdays(),
      );

      final tasks = await repository.watchDueList().first;
      expect(tasks.map((t) => t.title), [
        'Put the bins out',
        'Replace the water filter',
      ]);
      expect(tasks.first.floatingSchedule, isNull);
      expect(tasks.last.fixedSchedule, isNull);
    });
  });
}
