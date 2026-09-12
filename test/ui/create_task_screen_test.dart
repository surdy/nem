import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/ui/create_task_screen.dart';

void main() {
  late NemDatabase db;

  setUp(() => db = NemDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pumpForm(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: CreateTaskScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('requires a title', (tester) async {
    await pumpForm(tester);
    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    expect(find.text('Give the task a title'), findsOneWidget);
    expect(await TaskRepository(db).allTasks(), isEmpty);
  });

  testWidgets('rejects an interval below 1', (tester) async {
    await pumpForm(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Bleed radiators');
    await tester.enterText(find.widgetWithText(TextFormField, '3'), '0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    expect(find.text('At least 1'), findsOneWidget);
    expect(await TaskRepository(db).allTasks(), isEmpty);
  });

  testWidgets('creates a floating task with title, notes and interval', (
    tester,
  ) async {
    await pumpForm(tester);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Replace the water filter');
    await tester.enterText(fields.at(1), 'Cartridge is under the sink');
    await tester.enterText(fields.at(2), '3');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    final task = (await TaskRepository(db).allTasks()).single;
    expect(task.title, 'Replace the water filter');
    expect(task.notes, 'Cartridge is under the sink');
    expect(task.floatingSchedule?.intervalN, 3);
    expect(task.floatingSchedule?.intervalUnit, IntervalUnit.day);
    expect(task.dueDate, task.startDate.add(const Duration(days: 3)));
  });

  testWidgets('previews the derived first due date', (tester) async {
    await pumpForm(tester);
    expect(find.text('First due'), findsOneWidget);
  });
}
