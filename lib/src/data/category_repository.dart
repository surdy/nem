import 'package:drift/drift.dart';

import '../domain/category.dart';
import '../sync/outbox_store.dart';
import 'database.dart';
import 'ids.dart';

/// Reads and writes categories — the user-defined groupings that cut across
/// targets (CONTEXT.md — "Category") — and the membership of tasks in them.
///
/// Two tables, one repository, because a membership is meaningless on its own:
/// nothing outside this class ever wants a `task_categories` row, it wants "the
/// categories this task is in" or "is this task in any of these".
///
/// Every delete here is soft, like everywhere else in nem. A row is tombstoned
/// with `deleted_at` and kept, so a delete beats a stale update when sync
/// arrives (PLAN.md — Sync). Nothing in this class issues a `DELETE`.
class CategoryRepository {
  CategoryRepository(this._db);

  final NemDatabase _db;

  /// Every write that changes what a category or a membership row says queues
  /// it for push (#14). Both tables are plain mutable state — a name, a colour,
  /// a tombstone — so both merge by last-write-wins on `updated_at` like
  /// everything that is not a completion (PLAN.md — Sync).
  late final OutboxStore _outbox = OutboxStore(_db);

  /// Live categories, alphabetically.
  Stream<List<Category>> watchCategories() {
    final query = _db.select(_db.categories)
      ..where((c) => c.deletedAt.isNull())
      ..orderBy([(c) => OrderingTerm(expression: c.name)]);
    return query.watch().map((rows) => rows.map(_toDomain).toList());
  }

  /// One live category, or null once it has been deleted.
  Stream<Category?> watchCategory(String id) {
    final query = _db.select(_db.categories)
      ..where((c) => c.id.equals(id) & c.deletedAt.isNull());
    return query.watchSingleOrNull().map(
      (row) => row == null ? null : _toDomain(row),
    );
  }

  Future<List<Category>> allCategories() async {
    final rows =
        await (_db.select(_db.categories)
              ..where((c) => c.deletedAt.isNull())
              ..orderBy([(c) => OrderingTerm(expression: c.name)]))
            .get();
    return rows.map(_toDomain).toList();
  }

  Future<Category?> findCategory(String id) async {
    final row = await (_db.select(
      _db.categories,
    )..where((c) => c.id.equals(id) & c.deletedAt.isNull())).getSingleOrNull();
    return row == null ? null : _toDomain(row);
  }

  Future<Category> createCategory({
    required String name,
    int? color,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final category = Category(
      id: newId(),
      name: name.trim(),
      color: color,
      createdAt: timestamp,
      updatedAt: timestamp,
    );

    await _db
        .into(_db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: category.id,
            name: category.name,
            color: Value(category.color),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    await _outbox.enqueue(
      _db.categories.actualTableName,
      category.id,
      now: timestamp,
    );
    return category;
  }

  /// Renames [id] and recolours it at the same time.
  ///
  /// Returns null when there is no live category under that id: a deleted
  /// category cannot be renamed back into existence, because a delete outranks
  /// an update (PLAN.md — Sync).
  Future<Category?> updateCategory({
    required String id,
    required String name,
    int? color,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(
      _db.categories,
    )..where((c) => c.id.equals(id) & c.deletedAt.isNull())).write(
      CategoriesCompanion(
        name: Value(name.trim()),
        color: Value(color),
        updatedAt: Value(timestamp),
      ),
    );
    await _outbox.enqueue(_db.categories.actualTableName, id, now: timestamp);
    return findCategory(id);
  }

  /// Soft-deletes [id] and leaves the tasks that were in it intact.
  ///
  /// Deleting "kitchen" is not deleting the work done in the kitchen. The tasks
  /// are not touched at all — not even their `updated_at` — because unlike a
  /// target, a category is not a column on the task: what has to go is the
  /// membership, and the membership is a row of its own.
  ///
  /// Those rows are tombstoned here, in the same transaction as the category,
  /// and queued alongside it. Leaving them live would work locally — every read
  /// joins the category and drops what does not resolve — but it would carry a
  /// membership of a deleted category to the other device, where it would sit
  /// forever waiting for a category that is never coming back. This mirrors
  /// `TargetRepository.softDeleteTarget`, which clears `target_id` in the same
  /// transaction for the same reason.
  Future<void> softDeleteCategory(String id, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    await _db.transaction(() async {
      final memberships = await (_db.select(
        _db.taskCategories,
      )..where((m) => m.categoryId.equals(id) & m.deletedAt.isNull())).get();
      for (final membership in memberships) {
        await (_db.update(
          _db.taskCategories,
        )..where((m) => m.id.equals(membership.id))).write(
          TaskCategoriesCompanion(
            deletedAt: Value(timestamp),
            updatedAt: Value(timestamp),
          ),
        );
        await _outbox.enqueue(
          _db.taskCategories.actualTableName,
          membership.id,
          now: timestamp,
        );
      }

      await (_db.update(_db.categories)..where((c) => c.id.equals(id))).write(
        CategoriesCompanion(
          deletedAt: Value(timestamp),
          updatedAt: Value(timestamp),
        ),
      );
      await _outbox.enqueue(_db.categories.actualTableName, id, now: timestamp);
    });
  }

  /// The live categories one task is in, alphabetically.
  ///
  /// A join rather than a read of the membership rows alone: a membership whose
  /// category has been deleted — or has not arrived yet, which a pull can
  /// legitimately produce (ADR 0011) — resolves to nothing and is simply not
  /// shown, rather than being an error or an empty chip.
  Stream<List<Category>> watchCategoriesForTask(String taskId) =>
      _categoriesForTaskQuery(taskId).watch().map(
        (rows) => [
          for (final row in rows) _toDomain(row.readTable(_db.categories)),
        ],
      );

  Future<List<Category>> categoriesForTask(String taskId) async {
    final rows = await _categoriesForTaskQuery(taskId).get();
    return [for (final row in rows) _toDomain(row.readTable(_db.categories))];
  }

  JoinedSelectStatement<HasResultSet, dynamic> _categoriesForTaskQuery(
    String taskId,
  ) {
    return _db.select(_db.categories).join([
        innerJoin(
          _db.taskCategories,
          _db.taskCategories.categoryId.equalsExp(_db.categories.id) &
              _db.taskCategories.taskId.equals(taskId) &
              _db.taskCategories.deletedAt.isNull(),
        ),
      ])
      ..where(_db.categories.deletedAt.isNull())
      ..orderBy([OrderingTerm(expression: _db.categories.name)]);
  }

  /// Puts [taskId] in exactly [categoryIds] and in nothing else.
  ///
  /// The whole membership of one task in one call, because that is the shape of
  /// the decision the user makes: a sheet of categories with some ticked, saved
  /// once. Rows that are already right are left alone — untouched rows are not
  /// queued for push, so re-saving an unchanged sheet costs no sync traffic and
  /// cannot move a clock the other device is comparing against.
  ///
  /// Adding a task back to a category it was removed from re-points the row
  /// that is already there rather than inserting a second one, which is what
  /// the unique index on `(task_id, category_id)` is for and what keeps the two
  /// devices converging on one row per membership.
  Future<void> setCategoriesForTask(
    String taskId,
    Set<String> categoryIds, {
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    await _db.transaction(() async {
      // Tombstoned rows included: they are what "put it back" re-points.
      final existing = await (_db.select(
        _db.taskCategories,
      )..where((m) => m.taskId.equals(taskId))).get();
      final byCategory = {for (final row in existing) row.categoryId: row};

      for (final categoryId in categoryIds) {
        final row = byCategory[categoryId];
        if (row != null && row.deletedAt == null) continue;
        if (row == null) {
          final id = newId();
          await _db
              .into(_db.taskCategories)
              .insert(
                TaskCategoriesCompanion.insert(
                  id: id,
                  taskId: taskId,
                  categoryId: categoryId,
                  createdAt: timestamp,
                  updatedAt: timestamp,
                ),
              );
          await _outbox.enqueue(
            _db.taskCategories.actualTableName,
            id,
            now: timestamp,
          );
        } else {
          await (_db.update(
            _db.taskCategories,
          )..where((m) => m.id.equals(row.id))).write(
            TaskCategoriesCompanion(
              deletedAt: const Value(null),
              updatedAt: Value(timestamp),
            ),
          );
          await _outbox.enqueue(
            _db.taskCategories.actualTableName,
            row.id,
            now: timestamp,
          );
        }
      }

      for (final row in existing) {
        if (row.deletedAt != null) continue;
        if (categoryIds.contains(row.categoryId)) continue;
        await (_db.update(
          _db.taskCategories,
        )..where((m) => m.id.equals(row.id))).write(
          TaskCategoriesCompanion(
            deletedAt: Value(timestamp),
            updatedAt: Value(timestamp),
          ),
        );
        await _outbox.enqueue(
          _db.taskCategories.actualTableName,
          row.id,
          now: timestamp,
        );
      }
    });
  }

  /// The ids of the live categories [taskId] is in — what a picker starts from.
  Future<Set<String>> categoryIdsForTask(String taskId) async =>
      (await categoriesForTask(taskId)).map((c) => c.id).toSet();

  Category _toDomain(CategoryRow row) => Category(
    id: row.id,
    name: row.name,
    color: row.color,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}
