import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/clock.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/reminder.dart';
import 'package:nem/src/ui/due_list_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import '../notifications/fake_digest_notifier.dart';
import '../notifications/fake_reminder_notifier.dart';

void main() {
  late NemDatabase db;
  late TaskRepository repository;
  late FakeReminderNotifier reminders;
  final now = DateTime(2026, 6, 15, 10, 0);

  // Fixed schedules resolve their occurrences against the tz database
  // (ADR 0010).
  setUpAll(tz_data.initializeTimeZones);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
    reminders = FakeReminderNotifier();
  });

  tearDown(() => db.close());

  Future<void> pumpDueList(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(FakeDigestNotifier()),
          reminderNotifierProvider.overrideWithValue(reminders),
          clockProvider.overrideWithValue(() => now),
          nowProvider.overrideWithValue(now),
        ],
        child: const MaterialApp(home: DueListScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  testWidgets('shows an empty state when nothing is due', (tester) async {
    await pumpDueList(tester);
    expect(find.textContaining('Nothing due'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('groups tasks Overdue, Today and Soon', (tester) async {
    // Due 5 June — ten days overdue at the pinned now.
    await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );
    // Due 15 June — today.
    await repository.createFloatingTask(
      title: 'Water the plants',
      intervalN: 14,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );
    // Due 1 July — soon.
    await repository.createFloatingTask(
      title: 'Service the boiler',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDueList(tester);

    expect(find.text('OVERDUE'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('SOON'), findsOneWidget);
    expect(find.text('Replace the water filter'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('an overdue task shows how many days late it is', (tester) async {
    await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDueList(tester);

    expect(find.text('10 days late'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('completing a task records it and offers five seconds to '
      'undo', (tester) async {
    await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDueList(tester);
    expect(find.text('10 days late'), findsOneWidget);

    await tester.tap(find.byTooltip('Complete'));
    await tester.pumpAndSettle();

    // The completion is on disk, and the task has rescheduled off the back of
    // it rather than waiting for the undo window to lapse.
    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, isNotNull);
    expect(find.text('10 days late'), findsNothing);

    expect(find.text('Completed Replace the water filter'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 5),
    );

    // Let the undo window lapse so no timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('undo takes the completion back', (tester) async {
    await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDueList(tester);
    await tester.tap(find.byTooltip('Complete'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    // Back where it started: overdue by the same ten days, no live completion.
    expect((await repository.allTasks()).single.lastCompletedAt, isNull);
    expect(find.text('10 days late'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the digest is set up from here', (tester) async {
    await pumpDueList(tester);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Daily digest'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a task due today carries no late badge', (tester) async {
    await repository.createFloatingTask(
      title: 'Water the plants',
      intervalN: 14,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDueList(tester);

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);
    await unmount(tester);
  });

  testWidgets('missed occurrences collapse into a single row', (tester) async {
    // Mondays from 25 May 2026. By Monday 15 June the 25th, the 1st and the
    // 8th have all gone by uncompleted (ADR 0007).
    await repository.createFixedTask(
      title: 'Put the bins out',
      schedule: FixedSchedule.build(
        frequency: FixedFrequency.weekly,
        weekdays: {DateTime.monday},
        startDate: DateTime(2026, 5, 25),
        zoneId: 'Europe/London',
      ),
    );

    await pumpDueList(tester);

    // One row, not three, and it is late by the distance to the FIRST miss.
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('Put the bins out'), findsOneWidget);
    expect(find.text('21 days late'), findsOneWidget);
    expect(find.textContaining('every tuesday'), findsNothing);
    expect(find.textContaining('every monday'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('completing a fixed task clears the whole backlog at once', (
    tester,
  ) async {
    await repository.createFixedTask(
      title: 'Put the bins out',
      schedule: FixedSchedule.build(
        frequency: FixedFrequency.weekly,
        weekdays: {DateTime.monday},
        startDate: DateTime(2026, 5, 25),
        zoneId: 'Europe/London',
      ),
    );

    await pumpDueList(tester);
    await tester.tap(find.byTooltip('Complete'));
    await tester.pumpAndSettle();

    // Still one row, and no longer overdue: the intervening misses are gone
    // rather than queued up behind it.
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);
    expect(find.text('OVERDUE'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('regroups when the calendar day turns over with the app left '
      'open', (tester) async {
    // Due 15 June: today, at the moment the screen is opened.
    await repository.createFloatingTask(
      title: 'Water the plants',
      intervalN: 14,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    // The live clock rather than a pinned `now`, so this exercises the same
    // boundary timer the running app has.
    var clock = DateTime(2026, 6, 15, 23, 50);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(FakeDigestNotifier()),
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          clockProvider.overrideWithValue(() => clock),
        ],
        child: const MaterialApp(home: DueListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);

    // Midnight goes by with nobody touching the phone.
    clock = DateTime(2026, 6, 16, 0, 10);
    await tester.pump(const Duration(minutes: 20));
    await tester.pumpAndSettle();

    expect(find.text('OVERDUE'), findsOneWidget);
    expect(find.text('TODAY'), findsNothing);
    expect(find.text('1 day late'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the list does not rebuild on its own within a day', (
    tester,
  ) async {
    await repository.createFloatingTask(
      title: 'Water the plants',
      intervalN: 14,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    var clock = DateTime(2026, 6, 15, 9);
    var groupings = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(FakeDigestNotifier()),
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          clockProvider.overrideWithValue(() {
            groupings++;
            return clock;
          }),
        ],
        child: const MaterialApp(home: DueListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final atRest = groupings;
    // Fourteen hours of the same day. A clock that ticked more often than the
    // grouping can change would read itself hundreds of times here.
    for (var hour = 10; hour < 24; hour++) {
      clock = DateTime(2026, 6, 15, hour);
      await tester.pump(const Duration(hours: 1));
    }

    expect(groupings, atRest);
    expect(find.text('TODAY'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a snoozed task is marked as snoozed rather than left looking '
      'merely upcoming', (tester) async {
    await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDueList(tester);
    expect(find.text('10 days late'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snooze 3 days'));
    await tester.pumpAndSettle();

    // Out of Overdue and into Soon — but wearing the chip that says why.
    expect(find.text('OVERDUE'), findsNothing);
    expect(find.text('SOON'), findsOneWidget);
    expect(find.text('Snoozed'), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);
    expect(find.text('Due 18 Jun 2026'), findsNothing);
    expect(find.textContaining('Due 18 Jun 2026'), findsOneWidget);

    // And no completion was written for it.
    final task = (await repository.allTasks()).single;
    expect(task.lastCompletedAt, isNull);
    expect(await repository.completionsFor(task.id), isEmpty);

    await unmount(tester);
  });

  testWidgets('completing a task takes back the reminder it had pending', (
    tester,
  ) async {
    // The acceptance criterion at the level the user meets it: tick the task
    // off, and nothing arrives this evening to tell you to do it.
    final task = await repository.createFloatingTask(
      title: 'Put the bins out',
      intervalN: 7,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 8),
    );
    await repository.setReminderTime(task.id, const ReminderTime(hour: 19));

    await pumpDueList(tester);

    await tester.tap(find.byTooltip('Complete'));
    await tester.pumpAndSettle();

    // The completion re-planned, and the re-plan does not contain a reminder
    // for work that has just been done.
    expect(reminders.cancelCount, 1);
    expect(reminders.forTask(task.id), isEmpty);

    // Let the undo window lapse so no timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('a snooze can be taken back from the snackbar', (tester) async {
    await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDueList(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snooze 3 days'));
    await tester.pumpAndSettle();

    expect(
      find.text('Snoozed Replace the water filter for 3 days'),
      findsOneWidget,
    );
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    // Back where it started, ten days late.
    expect(find.text('10 days late'), findsOneWidget);
    expect(find.text('Snoozed'), findsNothing);
    await unmount(tester);
  });

  testWidgets('archiving takes a task off the list without touching its '
      'completions', (tester) async {
    final task = await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );
    await repository.recordCompletion(
      task.id,
      completedAt: DateTime(2026, 6, 2, 9),
      now: DateTime(2026, 6, 2, 9),
    );

    await pumpDueList(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing due'), findsOneWidget);
    expect(find.text('Archived Replace the water filter'), findsOneWidget);
    expect((await repository.completionsFor(task.id)).length, 1);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('undo puts the reminder back', (tester) async {
    final task = await repository.createFloatingTask(
      title: 'Put the bins out',
      intervalN: 7,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 8),
    );
    await repository.setReminderTime(task.id, const ReminderTime(hour: 19));

    await pumpDueList(tester);
    await tester.tap(find.byTooltip('Complete'));
    await tester.pumpAndSettle();
    expect(reminders.forTask(task.id), isEmpty);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(reminders.forTask(task.id), isNotEmpty);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('the archive is reachable from here, and restores a task to '
      'the list', (tester) async {
    final task = await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );
    await repository.archiveTask(task.id);

    await pumpDueList(tester);
    expect(find.textContaining('Nothing due'), findsOneWidget);

    await tester.tap(find.byTooltip('Archived'));
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Replace the water filter'), findsOneWidget);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing archived'), findsOneWidget);

    // And it is back on the list underneath, still ten days late.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('10 days late'), findsOneWidget);
    await unmount(tester);
  });
}
