import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/ui/due_list_screen.dart';

void main() {
  late NemDatabase db;
  late TaskRepository repository;
  final now = DateTime(2026, 6, 15, 10, 0);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  Future<void> pumpDueList(WidgetTester tester) async {
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
}
