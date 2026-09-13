import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/category_repository.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/category.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/ui/category_form_screen.dart';
import 'package:nem/src/ui/category_list_screen.dart';

void main() {
  late NemDatabase db;
  late CategoryRepository repository;
  late TaskRepository tasks;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = CategoryRepository(db);
    tasks = TaskRepository(db);
  });

  tearDown(() => db.close());

  Future<void> pumpCategories(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: CategoryListScreen()),
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

  testWidgets('explains what a category is when there are none', (
    tester,
  ) async {
    await pumpCategories(tester);
    expect(find.textContaining('No categories yet'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('creates a category with a colour from the form', (tester) async {
    await pumpCategories(tester);
    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();

    expect(find.byType(CategoryFormScreen), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'Kitchen');
    // Not the first swatch, so the assertion cannot pass on the default.
    await tester.tap(find.byKey(ValueKey('swatch-${categorySwatches[1]}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create category'));
    await tester.pumpAndSettle();

    final category = (await repository.allCategories()).single;
    expect(category.name, 'Kitchen');
    expect(category.color, categorySwatches[1]);
    expect(find.text('Kitchen'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('requires a name', (tester) async {
    await pumpCategories(tester);
    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create category'));
    await tester.pumpAndSettle();

    expect(find.text('Give the category a name'), findsOneWidget);
    expect(await repository.allCategories(), isEmpty);
    await unmount(tester);
  });

  testWidgets('renames and recolours a category', (tester) async {
    final created = await repository.createCategory(
      name: 'Kitchen',
      color: categorySwatches.first,
    );

    await pumpCategories(tester);
    await tester.tap(find.text('Kitchen'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'The kitchen');
    await tester.tap(find.byKey(ValueKey('swatch-${categorySwatches[2]}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final renamed = await repository.findCategory(created.id);
    expect(renamed?.name, 'The kitchen');
    expect(renamed?.color, categorySwatches[2]);
    expect(find.text('The kitchen'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('deleting a category keeps the tasks that were in it', (
    tester,
  ) async {
    final kitchen = await repository.createCategory(name: 'Kitchen');
    final task = await tasks.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
      now: DateTime(2026, 6, 1, 9),
    );
    await repository.setCategoriesForTask(task.id, {kitchen.id});

    await pumpCategories(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // The confirmation says what survives, because that is the part nobody can
    // see from here.
    expect(find.textContaining('The tasks in it are kept'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No categories yet'), findsOneWidget);
    expect(await repository.allCategories(), isEmpty);
    expect((await tasks.allTasks()).single.id, task.id);
    expect(await repository.categoriesForTask(task.id), isEmpty);
    await unmount(tester);
  });

  testWidgets('a delete can be called off', (tester) async {
    await repository.createCategory(name: 'Kitchen');

    await pumpCategories(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await repository.allCategories(), hasLength(1));
    expect(find.text('Kitchen'), findsOneWidget);
    await unmount(tester);
  });
}
