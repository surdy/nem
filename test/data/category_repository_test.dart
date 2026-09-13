import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/category_repository.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/category.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/sync/outbox_store.dart';

/// Categories, and the membership of tasks in them (CONTEXT.md — "Category").
///
/// A category is a grouping that cuts across targets, and the whole of what
/// makes it different from a target is in this file: a task belongs to several
/// of them at once, and deleting one deletes no work.
void main() {
  late NemDatabase db;
  late CategoryRepository categories;
  late TaskRepository tasks;
  late OutboxStore outbox;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    categories = CategoryRepository(db);
    tasks = TaskRepository(db);
    outbox = OutboxStore(db);
  });

  tearDown(() => db.close());

  Future<String> createTask(String title, {DateTime? now}) async {
    final task = await tasks.createFloatingTask(
      title: title,
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
      now: now ?? DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  group('creating, renaming and colouring', () {
    test('a category is created with a name and a colour', () async {
      final created = await categories.createCategory(
        name: '  Kitchen  ',
        color: categorySwatches.first,
        now: DateTime(2026, 6, 1, 9),
      );

      expect(created.name, 'Kitchen');
      expect(created.color, categorySwatches.first);

      final stored = (await categories.allCategories()).single;
      expect(stored.id, created.id);
      expect(stored.name, 'Kitchen');
      expect(stored.color, categorySwatches.first);
    });

    test('a category with no colour keeps none, rather than being given '
        'one', () async {
      final created = await categories.createCategory(name: 'Admin');
      expect(created.color, isNull);
      expect((await categories.findCategory(created.id))?.color, isNull);
    });

    test('renaming and recolouring move updated_at', () async {
      final created = await categories.createCategory(
        name: 'Kitchen',
        color: categorySwatches.first,
        now: DateTime(2026, 6, 1, 9),
      );

      final renamed = await categories.updateCategory(
        id: created.id,
        name: 'The kitchen',
        color: categorySwatches[1],
        now: DateTime(2026, 6, 2, 9),
      );

      expect(renamed?.name, 'The kitchen');
      expect(renamed?.color, categorySwatches[1]);
      expect(renamed?.updatedAt, DateTime(2026, 6, 2, 9));
      expect(renamed?.createdAt, DateTime(2026, 6, 1, 9));
    });

    test('a deleted category cannot be renamed back into existence', () async {
      final created = await categories.createCategory(name: 'Kitchen');
      await categories.softDeleteCategory(created.id);

      expect(
        await categories.updateCategory(id: created.id, name: 'Kitchen again'),
        isNull,
      );
      expect(await categories.allCategories(), isEmpty);
    });

    test('categories come back alphabetically', () async {
      await categories.createCategory(name: 'Kitchen');
      await categories.createCategory(name: 'Admin');
      await categories.createCategory(name: 'The car');

      expect((await categories.allCategories()).map((c) => c.name), [
        'Admin',
        'Kitchen',
        'The car',
      ]);
    });
  });

  group('membership', () {
    test('a task belongs to several categories at once', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final admin = await categories.createCategory(name: 'Admin');
      final annual = await categories.createCategory(name: 'Annual');
      final taskId = await createTask('Service the boiler');

      await categories.setCategoriesForTask(taskId, {
        kitchen.id,
        admin.id,
        annual.id,
      });

      expect((await categories.categoriesForTask(taskId)).map((c) => c.name), [
        'Admin',
        'Annual',
        'Kitchen',
      ]);
    });

    test('taking a task out of a category tombstones the membership rather '
        'than deleting it', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await categories.setCategoriesForTask(taskId, {kitchen.id});

      await categories.setCategoriesForTask(taskId, const {});

      expect(await categories.categoriesForTask(taskId), isEmpty);
      // The row is still on disk, tombstoned — which is what stops the other
      // device resurrecting the membership on its next push.
      final rows = await db.select(db.taskCategories).get();
      expect(rows, hasLength(1));
      expect(rows.single.deletedAt, isNotNull);
    });

    test(
      'putting a task back re-points the row that is already there',
      () async {
        final kitchen = await categories.createCategory(name: 'Kitchen');
        final taskId = await createTask('Replace the water filter');

        await categories.setCategoriesForTask(taskId, {kitchen.id});
        final first = (await db.select(db.taskCategories).get()).single.id;
        await categories.setCategoriesForTask(taskId, const {});
        await categories.setCategoriesForTask(taskId, {kitchen.id});

        final rows = await db.select(db.taskCategories).get();
        expect(rows, hasLength(1));
        expect(rows.single.id, first);
        expect(rows.single.deletedAt, isNull);
        expect(
          (await categories.categoriesForTask(taskId)).single.id,
          kitchen.id,
        );
      },
    );

    test('saving an unchanged membership queues nothing', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await categories.setCategoriesForTask(taskId, {kitchen.id});

      final entries = await outbox.pending();
      await categories.setCategoriesForTask(taskId, {kitchen.id});

      // The same queue, not a longer one: nothing about the row changed, so
      // there is nothing to push and no clock to move.
      expect(
        (await outbox.pending()).map((e) => '${e.table}/${e.rowId}'),
        entries.map((e) => '${e.table}/${e.rowId}'),
      );
    });

    test('a membership of a category that does not resolve is not '
        'shown', () async {
      final taskId = await createTask('Replace the water filter');
      // A pull can deliver a membership before the category it names
      // (ADR 0011), and there is no constraint to refuse it.
      await categories.setCategoriesForTask(taskId, {'from-the-other-phone'});

      expect(await categories.categoriesForTask(taskId), isEmpty);
      expect(await db.select(db.taskCategories).get(), hasLength(1));
    });
  });

  group('soft delete', () {
    test('deleting a category keeps its tasks, their schedules and their '
        'history', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await tasks.recordCompletion(
        taskId,
        completedAt: DateTime(2026, 6, 5, 9),
        now: DateTime(2026, 6, 5, 9),
      );
      await categories.setCategoriesForTask(taskId, {kitchen.id});

      await categories.softDeleteCategory(
        kitchen.id,
        now: DateTime(2026, 6, 6, 9),
      );

      final task = (await tasks.allTasks()).single;
      expect(task.id, taskId);
      expect(task.lastCompletedAt, DateTime(2026, 6, 5, 9));
      expect(task.dueDate, DateTime(2026, 7, 5, 9));
      expect(await tasks.completionsFor(taskId), hasLength(1));
      expect(await categories.categoriesForTask(taskId), isEmpty);
    });

    test('deleting a category tombstones its memberships in the same '
        'breath, and queues both', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await categories.setCategoriesForTask(taskId, {kitchen.id});
      final membershipId = (await db.select(db.taskCategories).get()).single.id;

      await categories.softDeleteCategory(
        kitchen.id,
        now: DateTime(2026, 6, 6, 9),
      );

      final row = await (db.select(
        db.taskCategories,
      )..where((m) => m.id.equals(membershipId))).getSingle();
      expect(row.deletedAt, DateTime(2026, 6, 6, 9));
      expect(row.updatedAt, DateTime(2026, 6, 6, 9));

      final queued = {
        for (final entry in await outbox.pending())
          '${entry.table}/${entry.rowId}',
      };
      expect(queued, contains('categories/${kitchen.id}'));
      expect(queued, contains('task_categories/$membershipId'));
    });

    test('a delete is soft: nothing is ever removed from either '
        'table', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await categories.setCategoriesForTask(taskId, {kitchen.id});

      await categories.softDeleteCategory(kitchen.id);

      expect(await db.select(db.categories).get(), hasLength(1));
      expect(await db.select(db.taskCategories).get(), hasLength(1));
    });
  });

  group('filtering the due list', () {
    test('no categories means no filter at all', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final filtered = await createTask('Replace the water filter');
      await createTask('Do the accounts');
      await categories.setCategoriesForTask(filtered, {kitchen.id});

      final due = await tasks.watchDueList().first;
      expect(due.map((t) => t.title), [
        'Do the accounts',
        'Replace the water filter',
      ]);
    });

    test('one category narrows the list to it', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final filterId = await createTask('Replace the water filter');
      await createTask('Do the accounts');
      await categories.setCategoriesForTask(filterId, {kitchen.id});

      final due = await tasks.watchDueList(categoryIds: {kitchen.id}).first;
      expect(due.map((t) => t.title), ['Replace the water filter']);
    });

    test('several categories mean any of them, and a task in two appears '
        'once', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final car = await categories.createCategory(name: 'The car');
      final admin = await categories.createCategory(name: 'Admin');

      final both = await createTask('Both of them');
      final carOnly = await createTask('Check the tyres');
      final adminOnly = await createTask('Do the accounts');
      await categories.setCategoriesForTask(both, {kitchen.id, car.id});
      await categories.setCategoriesForTask(carOnly, {car.id});
      await categories.setCategoriesForTask(adminOnly, {admin.id});

      final due = await tasks
          .watchDueList(categoryIds: {kitchen.id, car.id})
          .first;
      expect(due.map((t) => t.title), ['Both of them', 'Check the tyres']);
    });

    test('a task taken out of the category leaves the filtered list', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await categories.setCategoriesForTask(taskId, {kitchen.id});

      await categories.setCategoriesForTask(taskId, const {});

      expect(
        await tasks.watchDueList(categoryIds: {kitchen.id}).first,
        isEmpty,
      );
      // And it is still on the unfiltered list, because nothing happened to
      // the task itself.
      expect(await tasks.watchDueList().first, hasLength(1));
    });

    test('archived tasks stay off the filtered list too', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await categories.setCategoriesForTask(taskId, {kitchen.id});
      await tasks.archiveTask(taskId);

      expect(
        await tasks.watchDueList(categoryIds: {kitchen.id}).first,
        isEmpty,
      );
    });
  });

  group('the outbox', () {
    test('creating, renaming and deleting a category each queue it', () async {
      final created = await categories.createCategory(
        name: 'Kitchen',
        now: DateTime(2026, 6, 1, 9),
      );
      expect(await outbox.count(), 1);

      await outbox.remove('categories', created.id);
      await categories.updateCategory(
        id: created.id,
        name: 'The kitchen',
        now: DateTime(2026, 6, 2, 9),
      );
      expect(await outbox.count(), 1);

      await outbox.remove('categories', created.id);
      await categories.softDeleteCategory(
        created.id,
        now: DateTime(2026, 6, 3, 9),
      );
      expect(
        (await outbox.pending()).single.table,
        db.categories.actualTableName,
      );
    });

    test('a membership is queued as a row of its own', () async {
      final kitchen = await categories.createCategory(name: 'Kitchen');
      final taskId = await createTask('Replace the water filter');
      await outbox.remove('categories', kitchen.id);
      await outbox.remove('tasks', taskId);

      await categories.setCategoriesForTask(taskId, {kitchen.id});

      final entry = (await outbox.pending()).single;
      expect(entry.table, 'task_categories');
      expect(entry.rowId, (await db.select(db.taskCategories).get()).single.id);
    });
  });
}
