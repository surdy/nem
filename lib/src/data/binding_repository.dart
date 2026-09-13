import 'package:drift/drift.dart';

import '../domain/binding.dart';
import '../domain/scan.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import 'database.dart';
import 'ids.dart';
import 'target_repository.dart';
import 'task_repository.dart';

/// Reads and writes bindings — the association between one scannable code and
/// one target (CONTEXT.md — "Binding").
///
/// Provisioning goes through here: generating a label for a target, and binding
/// a product barcode that already existed. Writing an NFC tag will too, in #8;
/// nothing in this class knows or cares which reader produced a value.
///
/// Every delete is soft, like everywhere else in nem (PLAN.md — Sync).
class BindingRepository {
  BindingRepository(this._db);

  final NemDatabase _db;

  /// The codes bound to one target, oldest first.
  Stream<List<Binding>> watchBindingsForTarget(String targetId) {
    final query = _db.select(_db.bindings)
      ..where((b) => b.targetId.equals(targetId) & b.deletedAt.isNull())
      ..orderBy([(b) => OrderingTerm(expression: b.createdAt)]);
    return query.watch().map((rows) => rows.map(_toDomain).toList());
  }

  /// The live binding for one kind and value, or null.
  ///
  /// This is the first step of every scan (PLAN.md — Resolution), and the
  /// reason the unique index exists: the answer is one row or none, never a
  /// choice between two targets.
  Future<Binding?> findBinding(BindingKind kind, String value) async {
    final row =
        await (_db.select(_db.bindings)..where(
              (b) =>
                  b.kind.equalsValue(kind) &
                  b.value.equals(value) &
                  b.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    return row == null ? null : _toDomain(row);
  }

  Future<List<Binding>> bindingsForTarget(String targetId) async {
    final rows = await (_db.select(
      _db.bindings,
    )..where((b) => b.targetId.equals(targetId) & b.deletedAt.isNull())).get();
    return rows.map(_toDomain).toList();
  }

  /// Binds [value] to [targetId] as a code of [kind].
  ///
  /// Idempotent, and it re-points rather than duplicates. `(kind, value)` is
  /// unique including tombstoned rows, so a code that was unbound — or bound to
  /// a different target — is the same row brought back to life under a new
  /// target. Inserting a second row would fail the index, and working around
  /// the index by hard-deleting the first would give sync a row to resurrect.
  Future<Binding> bind({
    required String targetId,
    required BindingKind kind,
    required String value,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final trimmed = value.trim();

    return _db.transaction(() async {
      final existing =
          await (_db.select(_db.bindings)..where(
                (b) => b.kind.equalsValue(kind) & b.value.equals(trimmed),
              ))
              .getSingleOrNull();

      if (existing != null) {
        await (_db.update(
          _db.bindings,
        )..where((b) => b.id.equals(existing.id))).write(
          BindingsCompanion(
            targetId: Value(targetId),
            deletedAt: const Value(null),
            updatedAt: Value(timestamp),
          ),
        );
        return Binding(
          id: existing.id,
          targetId: targetId,
          kind: kind,
          value: trimmed,
          createdAt: existing.createdAt,
          updatedAt: timestamp,
        );
      }

      final binding = Binding(
        id: newId(),
        targetId: targetId,
        kind: kind,
        value: trimmed,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      await _db
          .into(_db.bindings)
          .insert(
            BindingsCompanion.insert(
              id: binding.id,
              targetId: binding.targetId,
              kind: binding.kind,
              value: binding.value,
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      return binding;
    });
  }

  /// The label binding for [targetId], creating it if the target has none.
  ///
  /// A label encodes `nem://t/<uuid>` (ADR 0009), so its stored value is the
  /// target's own id — the code and the target are the same uuid, and printing
  /// the same label twice is one binding, not two. The row still has to exist:
  /// resolution goes through the bindings table, so a label nobody recorded is
  /// a code nem does not know.
  Future<Binding> generateLabel(String targetId, {DateTime? now}) => bind(
    targetId: targetId,
    kind: BindingKind.label,
    value: targetId,
    now: now,
  );

  /// Soft-deletes a binding: the code stops resolving, the target is untouched.
  Future<void> unbind(String id, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    await (_db.update(
      _db.bindings,
    )..where((b) => b.id.equals(id) & b.deletedAt.isNull())).write(
      BindingsCompanion(
        deletedAt: Value(timestamp),
        updatedAt: Value(timestamp),
      ),
    );
  }

  Binding _toDomain(BindingRow row) => Binding(
    id: row.id,
    targetId: row.targetId,
    kind: row.kind,
    value: row.value,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}

/// [ScanLookup] over the real repositories.
///
/// The adapter exists so [ScanResolver] can stay a pure decision: it is handed
/// three answers and never learns that drift is behind them, which is what lets
/// every branch of the resolution flow be tested against a map instead of a
/// database.
class RepositoryScanLookup implements ScanLookup {
  const RepositoryScanLookup({
    required this.bindings,
    required this.targets,
    required this.tasks,
  });

  final BindingRepository bindings;
  final TargetRepository targets;
  final TaskRepository tasks;

  @override
  Future<Binding?> findBinding(BindingKind kind, String value) =>
      bindings.findBinding(kind, value);

  @override
  Future<Target?> findTarget(String id) => targets.findTarget(id);

  @override
  Future<List<Task>> tasksForTarget(String targetId) =>
      tasks.tasksForTarget(targetId);
}
