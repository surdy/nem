import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/target.dart';
import 'package:nem/src/ui/target_detail_screen.dart';

void main() {
  late NemDatabase db;
  late TargetRepository targets;
  late TaskRepository tasks;
  late Target boiler;
  final now = DateTime(2026, 6, 15, 10, 0);

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    targets = TargetRepository(db);
    tasks = TaskRepository(db);
    boiler = await targets.createTarget(
      name: 'The boiler',
      description: 'In the airing cupboard',
    );
  });

  tearDown(() => db.close());

  Future<void> pumpDetail(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(now),
        ],
        child: MaterialApp(home: TargetDetailScreen(targetId: boiler.id)),
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

  testWidgets('shows the target and its description', (tester) async {
    await pumpDetail(tester);
    expect(find.text('The boiler'), findsOneWidget);
    expect(find.text('In the airing cupboard'), findsOneWidget);
    expect(find.textContaining('No tasks here yet'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('lists this target\'s tasks with their due dates', (
    tester,
  ) async {
    // Due 1 July 2026 — upcoming at the pinned now.
    await tasks.createFloatingTask(
      title: 'Service the boiler',
      targetId: boiler.id,
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );
    // Due 5 June 2026 — ten days overdue.
    await tasks.createFloatingTask(
      title: 'Bleed the radiators',
      targetId: boiler.id,
      intervalN: 4,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );
    // Somewhere else entirely.
    await tasks.createFloatingTask(
      title: 'Water the plants',
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpDetail(tester);

    expect(find.text('Service the boiler'), findsOneWidget);
    expect(find.text('Due 1 Jul 2026'), findsOneWidget);
    expect(find.text('Bleed the radiators'), findsOneWidget);
    expect(find.text('Due 5 Jun 2026 · 10 days late'), findsOneWidget);
    expect(find.text('Water the plants'), findsNothing);
    await unmount(tester);
  });

  testWidgets('deleting the target keeps its tasks and unassigns them', (
    tester,
  ) async {
    final task = await tasks.createFloatingTask(
      title: 'Service the boiler',
      targetId: boiler.id,
      intervalN: 1,
      intervalUnit: IntervalUnit.year,
      startDate: DateTime(2026, 2, 1),
    );

    await pumpDetail(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete target'));
    await tester.pumpAndSettle();

    // The dialog says what will happen to the work, because that is the part
    // that is not obvious.
    expect(find.textContaining('Its tasks are kept'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await targets.allTargets(), isEmpty);
    final survivor = (await tasks.allTasks()).single;
    expect(survivor.id, task.id);
    expect(survivor.targetId, isNull);
    await unmount(tester);
  });

  testWidgets('cancelling the delete leaves the target alone', (tester) async {
    await pumpDetail(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete target'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect((await targets.allTargets()).single.id, boiler.id);
    await unmount(tester);
  });
}
