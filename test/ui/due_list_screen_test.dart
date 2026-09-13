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
