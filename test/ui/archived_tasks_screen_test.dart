import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/ui/archived_tasks_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  late NemDatabase db;
  late TaskRepository repository;
  final now = DateTime(2026, 6, 15, 10);

  setUpAll(tz_data.initializeTimeZones);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  Future<void> pumpArchive(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(now),
        ],
        child: const MaterialApp(home: ArchivedTasksScreen()),
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

  /// A task completed twice, then retired.
  Future<String> archivedTaskId() async {
    final task = await repository.createFloatingTask(
      title: 'Descale the kettle',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 1, 1, 9),
    );
    await repository.recordCompletion(
      task.id,
      completedAt: DateTime(2026, 1, 5, 9),
      now: DateTime(2026, 1, 5, 9),
    );
    await repository.recordCompletion(
      task.id,
      completedAt: DateTime(2026, 2, 8, 9),
      now: DateTime(2026, 2, 8, 9),
    );
    await repository.archiveTask(task.id, now: DateTime(2026, 3, 1, 9));
    return task.id;
  }

  testWidgets('says so when nothing has been archived', (tester) async {
    await pumpArchive(tester);
    expect(find.textContaining('Nothing archived'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('lists archived tasks with what their history says', (
    tester,
  ) async {
    await archivedTaskId();
    await pumpArchive(tester);

    expect(find.text('Descale the kettle'), findsOneWidget);
    expect(find.textContaining('last done 8 Feb 2026'), findsOneWidget);
    expect(find.textContaining('every 30 days'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the completion history is still there to open', (tester) async {
    await archivedTaskId();
    await pumpArchive(tester);

    await tester.tap(find.text('Descale the kettle'));
    await tester.pumpAndSettle();

    expect(find.text('Archived'), findsWidgets);

    // Both completions survived being archived — that history is the reason
    // the row is kept at all rather than deleted. It sits below the reference
    // photo strip (#15), which is further down than the 600px test viewport
    // reaches, so the list is scrolled the way a thumb would scroll it.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.textContaining('8 Feb 2026'), findsWidgets);
    expect(find.textContaining('5 Jan 2026'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('restoring takes a task back out of the archive', (tester) async {
    final id = await archivedTaskId();
    await pumpArchive(tester);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing archived'), findsOneWidget);
    await unmount(tester);

    // Off the archive and back on the due list, not deleted.
    final task = (await repository.allTasks()).single;
    expect(task.id, id);
    expect(task.isArchived, isFalse);
  });
}
