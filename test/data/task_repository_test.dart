import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/due_status.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/reminder.dart';
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

  test('the schema is created at version 5', () async {
    expect(db.schemaVersion, 5);
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

    test(
      'a rule the editor cannot say keeps its bytes and its due date',
      () async {
        // The other half of ADR 0006: storage is more expressive than the UI,
        // so a hand-edited or imported rule has to survive being read, listed
        // and written back without being normalised into something else.
        const imported =
            'DTSTART;TZID=Europe/London:20260301T000000\n'
            'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU';
        final task = await repository.createFixedTask(
          title: 'Imported from a calendar',
          schedule: tuesdays(),
        );
        await db.customStatement('UPDATE tasks SET rrule = ? WHERE id = ?', [
          imported,
          task.id,
        ]);
        // Recomputing the caches is the write most likely to rewrite it.
        await repository.recomputeDerivedState();

        final stored = (await repository.allTasks()).single;
        expect(stored.rrule, imported);
        expect(stored.fixedSchedule?.isEditable, isFalse);
        expect(stored.fixedSchedule?.draft, isNull);
        expect(date(stored.dueDate!), '2026-03-08');

        final row = await db.select(db.tasks).getSingle();
        expect(row.rrule, imported);
      },
    );

    test('every rule the editor authors survives storage unchanged', () async {
      // editor → storage → editor, through the real column rather than a
      // string round trip: what comes back can be edited again.
      final drafts = [
        FixedScheduleDraft(
          frequency: FixedFrequency.monthly,
          monthlyOn: MonthlyOn.nthWeekday,
          startDate: DateTime(2026, 1, 20),
          zoneId: 'Europe/London',
          end: const EndsAfter(6),
        ),
        FixedScheduleDraft(
          frequency: FixedFrequency.monthly,
          interval: 2,
          monthlyOn: MonthlyOn.lastWeekday,
          startDate: DateTime(2026, 1, 27),
          zoneId: 'America/New_York',
          end: EndsOnDate(DateTime(2027, 6, 30)),
        ),
        FixedScheduleDraft(
          frequency: FixedFrequency.weekly,
          weekdays: {DateTime.tuesday, DateTime.friday},
          startDate: DateTime(2026, 1, 6, 9),
          zoneId: 'Australia/Lord_Howe',
        ),
      ];

      for (final draft in drafts) {
        final created = await repository.createFixedTask(
          title: draft.summary,
          schedule: draft.toSchedule(),
        );
        final stored = (await repository.allTasks()).singleWhere(
          (task) => task.id == created.id,
        );
        expect(stored.fixedSchedule?.draft, draft, reason: draft.summary);
        expect(stored.rrule, draft.toSchedule().encode());
        expect(stored.scheduleLabel, draft.summary);
        expect(stored.dueDate, isNotNull);
      }
    });

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

  group('snooze', () {
    final now = DateTime(2026, 6, 15, 10);

    /// A task due 5 June — ten days before [now].
    Future<String> overdueTask() async {
      final task = await repository.createFloatingTask(
        title: 'Replace the water filter',
        intervalN: 4,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 6, 1),
      );
      return task.id;
    }

    test('moves the due date forward without writing a completion', () async {
      final id = await overdueTask();

      final snoozed = await repository.snoozeTask(
        id,
        n: 3,
        unit: IntervalUnit.day,
        now: now,
      );

      expect(snoozed?.dueDate, DateTime(2026, 6, 18, 10));
      expect(snoozed?.snoozedUntil, DateTime(2026, 6, 18, 10));
      expect(snoozed?.snoozedAt, now);
      // The whole point: nothing says the work was done (ADR 0004).
      expect(await repository.completionsFor(id), isEmpty);
      expect(snoozed?.lastCompletedAt, isNull);
    });

    test('survives recomputeDerivedState, which is the whole reason it is '
        'not stored in due_date', () async {
      final id = await overdueTask();
      await repository.snoozeTask(id, n: 3, unit: IntervalUnit.day, now: now);

      // The recomputation that runs on every launch and after every sync pull.
      // It finds nothing to correct, because the snooze is one of its inputs
      // rather than something written over its output.
      expect(await repository.recomputeDerivedState(), 0);

      final task = (await repository.allTasks()).single;
      expect(task.dueDate, DateTime(2026, 6, 18, 10));
      expect(task.snoozedUntil, DateTime(2026, 6, 18, 10));

      // And the cache column itself carries the snooze, so the due list still
      // sorts on it in SQL.
      final row = await db.select(db.tasks).getSingle();
      expect(row.dueDate, DateTime(2026, 6, 18, 10));
    });

    test('takes an overdue task off the overdue list', () async {
      final id = await overdueTask();
      await repository.snoozeTask(id, n: 3, unit: IntervalUnit.day, now: now);

      final task = (await repository.watchDueList().first).single;
      expect(task.dueStatusAt(now), DueStatus.upcoming);
      expect(task.isSnoozedAt(now), isTrue, reason: 'not merely upcoming');
    });

    test('stops holding once the snooze comes due, and lateness counts from '
        'the snooze', () async {
      final id = await overdueTask();
      await repository.snoozeTask(id, n: 3, unit: IntervalUnit.day, now: now);
      final task = (await repository.allTasks()).single;

      expect(task.isSnoozedAt(DateTime(2026, 6, 18, 9)), isFalse);
      expect(task.dueStatusAt(DateTime(2026, 6, 18, 9)), DueStatus.dueToday);
      expect(
        overdueLabel(task.dueDate!, DateTime(2026, 6, 20, 9)),
        '2 days late',
        reason: 'late against the snooze, not the fifteen days since 5 June',
      );
    });

    test('snoozing again pushes out from the snooze, not from the '
        'schedule', () async {
      final id = await overdueTask();
      await repository.snoozeTask(id, n: 3, unit: IntervalUnit.day, now: now);
      final twice = await repository.snoozeTask(
        id,
        n: 3,
        unit: IntervalUnit.day,
        now: DateTime(2026, 6, 16, 10),
      );
      expect(twice?.dueDate, DateTime(2026, 6, 21, 10));
    });

    test('cancelling it gives the schedule its due date back', () async {
      final id = await overdueTask();
      await repository.snoozeTask(id, n: 3, unit: IntervalUnit.day, now: now);
      await repository.cancelSnooze(id, now: now);

      final task = (await repository.allTasks()).single;
      expect(task.snoozedUntil, isNull);
      expect(task.dueDate, DateTime(2026, 6, 5));
      expect(task.isSnoozedAt(now), isFalse);
    });

    test('doing the work spends the snooze, and undo brings it back', () async {
      final id = await overdueTask();
      await repository.snoozeTask(id, n: 1, unit: IntervalUnit.week, now: now);
      expect(
        (await repository.allTasks()).single.dueDate,
        DateTime(2026, 6, 22, 10),
      );

      final completion = await repository.recordCompletion(
        id,
        completedAt: DateTime(2026, 6, 16, 9),
        now: DateTime(2026, 6, 16, 9),
      );

      // Four days from the completion, not the week the snooze reached for:
      // the completion is the newer statement.
      final completed = (await repository.allTasks()).single;
      expect(completed.dueDate, DateTime(2026, 6, 20, 9));
      expect(
        completed.snoozedUntil,
        DateTime(2026, 6, 22, 10),
        reason: 'nothing is deleted to spend a snooze',
      );

      await repository.undoCompletion(
        completion,
        now: DateTime(2026, 6, 16, 9),
      );

      // Tombstoning the completion puts the snooze back in charge, without the
      // snoozed due date ever having been stored twice (ADR 0004).
      expect(
        (await repository.allTasks()).single.dueDate,
        DateTime(2026, 6, 22, 10),
      );
    });

    test('a fixed schedule keeps its rule, and its occurrences', () async {
      final task = await repository.createFixedTask(
        title: 'Put the bins out',
        schedule: tuesdays(),
      );
      final rule = task.rrule;

      final snoozed = await repository.snoozeTask(
        task.id,
        n: 3,
        unit: IntervalUnit.day,
        now: DateTime(2026, 1, 6, 10),
      );

      // The stored rule is byte-identical, so the calendar it generates has not
      // moved: the snooze sits on top of the occurrence, not in the rule
      // (ADR 0007).
      expect(snoozed?.rrule, rule);
      expect(
        snoozed!.fixedSchedule!
            .occurrencesFrom(DateTime(2026, 1, 6))
            .take(3)
            .map(date),
        ['2026-01-06', '2026-01-13', '2026-01-20'],
      );
      // The due date moved, though, and it is the snooze.
      expect(snoozed.dueDate, DateTime(2026, 1, 9, 10));
      expect(date(snoozed.scheduledDueDate!), '2026-01-06');
    });

    test('snoozing is an edit and bumps updated_at, unlike a '
        'completion', () async {
      final task = await repository.createFloatingTask(
        title: 'Replace the water filter',
        intervalN: 4,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 6, 1),
        now: DateTime(2026, 6, 1, 8),
      );
      expect(task.updatedAt, DateTime(2026, 6, 1, 8));

      await repository.snoozeTask(
        task.id,
        n: 3,
        unit: IntervalUnit.day,
        now: now,
      );

      // A completion deliberately leaves `updated_at` alone; a snooze is an
      // edit of the task and has to win last-write-wins when sync arrives.
      expect((await repository.allTasks()).single.updatedAt, now);
    });
  });

  group('archive', () {
    final now = DateTime(2026, 6, 15, 10);

    Future<String> completedTask() async {
      final task = await repository.createFloatingTask(
        title: 'Descale the kettle',
        intervalN: 30,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 1, 1),
      );
      await repository.recordCompletion(
        task.id,
        completedAt: DateTime(2026, 2, 1, 9),
        now: DateTime(2026, 2, 1, 9),
      );
      return task.id;
    }

    test('hides the task from the due list and keeps its '
        'completions', () async {
      final id = await completedTask();
      await repository.archiveTask(id, now: now);

      expect(await repository.watchDueList().first, isEmpty);
      // Nothing in the log was touched — that history is why the row is kept.
      expect(
        (await repository.completionsFor(id)).single.completedAt,
        DateTime(2026, 2, 1, 9),
      );
      expect((await repository.watchTask(id).first)?.isArchived, isTrue);
    });

    test('archived tasks can be browsed', () async {
      final id = await completedTask();
      await repository.archiveTask(id, now: now);

      final archived = (await repository.watchArchivedTasks().first).single;
      expect(archived.id, id);
      expect(archived.title, 'Descale the kettle');
      expect(archived.lastCompletedAt, DateTime(2026, 2, 1, 9));
    });

    test('and restored, with their history and their schedule', () async {
      final id = await completedTask();
      await repository.archiveTask(id, now: now);
      await repository.restoreTask(id, now: now);

      expect(await repository.watchArchivedTasks().first, isEmpty);
      final task = (await repository.watchDueList().first).single;
      expect(task.id, id);
      expect(task.isArchived, isFalse);
      // The schedule kept running underneath: 30 days after 1 February.
      expect(task.dueDate, DateTime(2026, 3, 3, 9));
      expect((await repository.completionsFor(id)).length, 1);
    });

    test('the due list and the archive are complements', () async {
      final archived = await completedTask();
      await repository.createFloatingTask(
        title: 'Water the plants',
        intervalN: 3,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 6, 1),
      );
      await repository.archiveTask(archived, now: now);

      expect((await repository.watchDueList().first).map((t) => t.title), [
        'Water the plants',
      ]);
      expect(
        (await repository.watchArchivedTasks().first).map((t) => t.title),
        ['Descale the kettle'],
      );
    });
  });

  group('per-task reminders', () {
    Future<String> taskId() async {
      final task = await repository.createFloatingTask(
        title: 'Put the bins out',
        intervalN: 1,
        intervalUnit: IntervalUnit.week,
        startDate: DateTime(2026, 6, 9),
      );
      return task.id;
    }

    test('a task starts with no reminder', () async {
      final stored = await repository.watchTask(await taskId()).first;
      expect(stored!.reminderTime, isNull);
      expect(stored.hasReminder, isFalse);
    });

    test('opting in stores the wall-clock time', () async {
      final id = await taskId();
      await repository.setReminderTime(id, const ReminderTime(hour: 19));

      final stored = await repository.watchTask(id).first;
      expect(stored!.reminderTime, const ReminderTime(hour: 19));
      expect(stored.hasReminder, isTrue);
    });

    test('it is stored as HH:mm, which is what the column is for', () async {
      final id = await taskId();
      await repository.setReminderTime(
        id,
        const ReminderTime(hour: 7, minute: 5),
      );

      final row = await (db.select(
        db.tasks,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(row.reminderTime, '07:05');
    });

    test('opting out clears the column', () async {
      final id = await taskId();
      await repository.setReminderTime(id, const ReminderTime(hour: 19));
      await repository.setReminderTime(id, null);

      final stored = await repository.watchTask(id).first;
      expect(stored!.reminderTime, isNull);
      final row = await (db.select(
        db.tasks,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(row.reminderTime, isNull);
    });

    test('setting a reminder is an edit, so updated_at moves', () async {
      final id = await taskId();
      final before = (await repository.watchTask(id).first)!.updatedAt;

      await repository.setReminderTime(
        id,
        const ReminderTime(hour: 19),
        now: before.add(const Duration(minutes: 1)),
      );

      final after = (await repository.watchTask(id).first)!.updatedAt;
      expect(after.isAfter(before), isTrue);
    });

    test('an unreadable stored value reads as no reminder', () async {
      // Hand-edited, or pulled from a device running something else. The
      // launch path must not die of it.
      final id = await taskId();
      await db.customStatement(
        "UPDATE tasks SET reminder_time = 'half seven' WHERE id = ?",
        [id],
      );

      final stored = await repository.watchTask(id).first;
      expect(stored!.reminderTime, isNull);
    });
  });
}
