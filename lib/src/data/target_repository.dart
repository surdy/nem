import 'package:drift/drift.dart';

import '../domain/target.dart';
import '../sync/outbox_store.dart';
import 'database.dart';
import 'ids.dart';

/// Reads and writes targets — the physical places and objects work is done on
/// (CONTEXT.md; ADR 0008).
///
/// Every delete here is soft. A row is tombstoned with `deleted_at` and kept, so
/// that once sync lands a delete beats a stale update rather than losing to one
/// (PLAN.md — Sync). Nothing in this class issues a `DELETE`.
class TargetRepository {
  TargetRepository(this._db);

  final NemDatabase _db;

  /// Every write that changes what a target row says queues it for push
  /// (#12). A target is plain mutable state — name, description, tombstone —
  /// so it merges by last-write-wins on `updated_at` like everything that is
  /// not a completion (PLAN.md — Sync).
  late final OutboxStore _outbox = OutboxStore(_db);

  /// Live targets, alphabetically.
  Stream<List<Target>> watchTargets() {
    final query = _db.select(_db.targets)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.watch().map((rows) => rows.map(_toDomain).toList());
  }

  /// One live target, or null once it has been deleted.
  Stream<Target?> watchTarget(String id) {
    final query = _db.select(_db.targets)
      ..where((t) => t.id.equals(id) & t.deletedAt.isNull());
    return query.watchSingleOrNull().map(
      (row) => row == null ? null : _toDomain(row),
    );
  }

  Future<List<Target>> allTargets() async {
    final rows = await (_db.select(
      _db.targets,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.map(_toDomain).toList();
  }

  Future<Target?> findTarget(String id) async {
    final row = await (_db.select(
      _db.targets,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    return row == null ? null : _toDomain(row);
  }

  Future<Target> createTarget({
    required String name,
    String? description,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final target = Target(
      id: newId(),
      name: name.trim(),
      description: _cleaned(description),
      createdAt: timestamp,
      updatedAt: timestamp,
    );

    await _db
        .into(_db.targets)
        .insert(
          TargetsCompanion.insert(
            id: target.id,
            name: target.name,
            description: Value(target.description),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    await _outbox.enqueue(
      _db.targets.actualTableName,
      target.id,
      now: timestamp,
    );
    return target;
  }

  /// Renames [id], replacing its description at the same time.
  ///
  /// Returns null when there is no live target under that id: a deleted target
  /// cannot be renamed back into existence, because a delete outranks an update
  /// (PLAN.md — Sync).
  Future<Target?> updateTarget({
    required String id,
    required String name,
    String? description,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(
      _db.targets,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      TargetsCompanion(
        name: Value(name.trim()),
        description: Value(_cleaned(description)),
        updatedAt: Value(timestamp),
      ),
    );
    await _outbox.enqueue(_db.targets.actualTableName, id, now: timestamp);
    return findTarget(id);
  }

  /// Soft-deletes [id] and leaves its tasks intact and unassigned.
  ///
  /// Deleting the boiler is not deleting the work done on the boiler — the tasks
  /// survive, they simply stop naming a target. Clearing `target_id` here, in
  /// the same transaction as the tombstone, is what unassigns them; filtering
  /// deleted targets out on read instead would leave every task pointing at a
  /// ghost, and sync would carry that dangling reference to the other device.
  Future<void> softDeleteTarget(String id, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    await _db.transaction(() async {
      // Read before the write, so the rows about to be unassigned can be
      // queued: once `target_id` is null there is no way to find them again.
      final affected = await (_db.select(
        _db.tasks,
      )..where((t) => t.targetId.equals(id))).get();
      await (_db.update(_db.tasks)..where((t) => t.targetId.equals(id))).write(
        TasksCompanion(
          targetId: const Value(null),
          // Bumped so the unassignment is a change sync can see, not a silent
          // local edit that a pull would undo.
          updatedAt: Value(timestamp),
        ),
      );
      // The unassignment is an edit of the *task*, so the task is pushed too,
      // and not only the target's tombstone — otherwise the other device would
      // apply the tombstone and keep a task pointing at it, which resolves to
      // nothing and reads as unassigned anyway (ADR 0011), but only after its
      // own next recomputation rather than now.
      for (final task in affected) {
        await _outbox.enqueue(
          _db.tasks.actualTableName,
          task.id,
          now: timestamp,
        );
      }
      await (_db.update(_db.targets)..where((t) => t.id.equals(id))).write(
        TargetsCompanion(
          deletedAt: Value(timestamp),
          updatedAt: Value(timestamp),
        ),
      );
      await _outbox.enqueue(_db.targets.actualTableName, id, now: timestamp);
    });
  }

  Target _toDomain(TargetRow row) => Target(
    id: row.id,
    name: row.name,
    description: row.description,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}

/// Trimmed, or null when there was nothing but whitespace.
String? _cleaned(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
