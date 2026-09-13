import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/ui/due_list_screen.dart';
import 'package:nem/src/ui/task_detail_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  late NemDatabase db;
  late TaskRepository repository;
  final now = DateTime(2026, 7, 10, 12);

  // Fixed schedules resolve against the tz database (ADR 0010).
  setUpAll(tz_data.initializeTimeZones);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  Future<String> weeklyTaskId() async {
    final task = await repository.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 7,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  Future<void> pumpDetail(WidgetTester tester, String taskId) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(now),
        ],
        child: MaterialApp(home: TaskDetailScreen(taskId: taskId)),
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

  testWidgets('a task with no completions says so', (tester) async {
    await pumpDetail(tester, await weeklyTaskId());

    expect(find.text('Replace the water filter'), findsOneWidget);
    expect(find.textContaining('No completions yet'), findsOneWidget);
    expect(find.text('0 completions'), findsNWidgets(2));
    await unmount(tester);
  });

  testWidgets('completions are listed with their date and source', (
    tester,
  ) async {
    final taskId = await weeklyTaskId();
    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 6, 8, 9),
      now: DateTime(2026, 6, 8, 9),
    );

    await pumpDetail(tester, taskId);

    expect(find.textContaining('8 Jun 2026'), findsOneWidget);
    expect(find.textContaining('By hand'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the gap between consecutive completions is shown', (
    tester,
  ) async {
    final taskId = await weeklyTaskId();
    for (final at in [DateTime(2026, 6, 15, 9), DateTime(2026, 7, 8, 9)]) {
      await repository.recordCompletion(taskId, completedAt: at, now: at);
    }

    await pumpDetail(tester, taskId);

    // Two missed weeks on a 7-day schedule, visible only as the gap (ADR
    // 0007).
    expect(find.textContaining('23 days later'), findsOneWidget);
    expect(find.text('16 days late'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the summary counts the last 30 and 90 days', (tester) async {
    final taskId = await weeklyTaskId();
    for (final at in [
      DateTime(2026, 6, 8, 9), // 32 days ago — outside 30, inside 90
      DateTime(2026, 6, 15, 9),
      DateTime(2026, 7, 8, 9),
    ]) {
      await repository.recordCompletion(taskId, completedAt: at, now: at);
    }

    await pumpDetail(tester, taskId);

    expect(find.text('Last 30 days'), findsOneWidget);
    expect(find.text('Last 90 days'), findsOneWidget);
    expect(find.text('2 completions'), findsOneWidget);
    expect(find.text('3 completions'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a tombstoned completion is not shown', (tester) async {
    final taskId = await weeklyTaskId();
    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 6, 15, 9),
      now: DateTime(2026, 6, 15, 9),
    );
    final undone = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 7, 8, 9),
      now: DateTime(2026, 7, 8, 9),
    );
    await repository.undoCompletion(undone, now: DateTime(2026, 7, 8, 10));

    await pumpDetail(tester, taskId);

    expect(find.textContaining('15 Jun 2026'), findsOneWidget);
    expect(find.textContaining('8 Jul 2026'), findsNothing);
    expect(find.text('1 completion'), findsNWidgets(2));
    await unmount(tester);
  });

  testWidgets('a correction replaces the row it retracted', (tester) async {
    final taskId = await weeklyTaskId();
    final original = await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 7, 8, 9),
      now: DateTime(2026, 7, 8, 9),
    );
    await repository.correctCompletion(
      original,
      completedAt: DateTime(2026, 7, 2, 9),
      now: DateTime(2026, 7, 8, 10),
    );

    await pumpDetail(tester, taskId);

    expect(find.textContaining('2 Jul 2026'), findsOneWidget);
    expect(find.textContaining('8 Jul 2026'), findsNothing);
    expect(find.text('1 completion'), findsNWidgets(2));
    await unmount(tester);
  });

  testWidgets('history survives a stale derived cache', (tester) async {
    final taskId = await weeklyTaskId();
    await repository.recordCompletion(
      taskId,
      completedAt: DateTime(2026, 7, 8, 9),
      now: DateTime(2026, 7, 8, 9),
    );
    // What a sync pull or a timezone change can leave behind before the next
    // recomputation. The screen reads the log, so none of this shows up.
    await (db.update(db.tasks)..where((t) => t.id.equals(taskId))).write(
      TasksCompanion(
        dueDate: Value(DateTime(1999, 1, 1)),
        lastCompletedAt: Value(DateTime(1999, 1, 1)),
      ),
    );

    await pumpDetail(tester, taskId);

    expect(find.textContaining('8 Jul 2026'), findsOneWidget);
    expect(find.textContaining('1999'), findsNothing);
    expect(find.textContaining('Due 15 Jul 2026'), findsOneWidget);
    await unmount(tester);
  });

  group('a fixed schedule', () {
    Future<String> binsTaskId({FixedScheduleDraft? draft}) async {
      final task = await repository.createFixedTask(
        title: 'Put the bins out',
        schedule:
            (draft ??
                    FixedScheduleDraft(
                      frequency: FixedFrequency.monthly,
                      monthlyOn: MonthlyOn.nthWeekday,
                      startDate: DateTime(2026, 1, 20),
                      zoneId: 'Europe/London',
                    ))
                .toSchedule(),
      );
      return task.id;
    }

    testWidgets('reads as the plain-language rule', (tester) async {
      await pumpDetail(tester, await binsTaskId());

      expect(find.text('Every month on the third Tuesday'), findsOneWidget);
      expect(find.byKey(const ValueKey('uneditable-rule')), findsNothing);
      await unmount(tester);
    });

    testWidgets('one nem cannot say is shown as itself, read-only', (
      tester,
    ) async {
      // A rule that reached storage by hand-edit or import (ADR 0006). It must
      // render rather than crash, and as the rule it is rather than as the
      // nearest thing the editor could have said.
      const imported =
          'DTSTART;TZID=Europe/London:20260301T000000\n'
          'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU';
      final taskId = await binsTaskId();
      await db.customStatement('UPDATE tasks SET rrule = ? WHERE id = ?', [
        imported,
        taskId,
      ]);

      await pumpDetail(tester, taskId);

      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('uneditable-rule')),
            )
            .data,
        imported,
      );
      expect(find.textContaining('cannot edit this calendar rule'), findsOne);
      // It is still a schedule: the due date comes from it as usual.
      expect(find.textContaining('Due 8 Mar 2026'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('one this build cannot even read still renders', (
      tester,
    ) async {
      final taskId = await binsTaskId();
      await db.customStatement(
        "UPDATE tasks SET rrule = 'RRULE:FREQ=NONSENSE' WHERE id = ?",
        [taskId],
      );

      await pumpDetail(tester, taskId);

      expect(find.text('RRULE:FREQ=NONSENSE'), findsOneWidget);
      expect(find.textContaining('Due '), findsNothing);
      await unmount(tester);
    });
  });

  testWidgets('the due list opens a task\'s history', (tester) async {
    await weeklyTaskId();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(now),
        ],
        child: const MaterialApp(home: DueListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Replace the water filter'));
    await tester.pumpAndSettle();

    expect(find.byType(TaskDetailScreen), findsOneWidget);
    expect(find.text('HISTORY'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a task can be snoozed from here, and says it is snoozed', (
    tester,
  ) async {
    final id = await weeklyTaskId();
    await pumpDetail(tester, id);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snooze 1 week'));
    await tester.pumpAndSettle();

    // Pushed a week out from today, with no completion behind it.
    expect(find.text('Snoozed'), findsOneWidget);
    expect(find.textContaining('Due 17 Jul 2026'), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);
    expect(await repository.completionsFor(id), isEmpty);

    // And it can be taken back from the same menu.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel snooze'));
    await tester.pumpAndSettle();

    expect(find.text('Snoozed'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('an archived task says so, and offers to be restored', (
    tester,
  ) async {
    final id = await weeklyTaskId();
    await repository.archiveTask(id, now: now);
    await pumpDetail(tester, id);

    expect(find.text('Archived'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    // Nothing is offered that does not make sense for a retired task.
    expect(find.text('Snooze 1 week'), findsNothing);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsNothing);
    await unmount(tester);

    expect((await repository.allTasks()).single.isArchived, isFalse);
  });
}
