import 'package:drift/drift.dart';

import '../domain/binding.dart';
import '../domain/scan.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import '../sync/outbox_store.dart';
import 'database.dart';
import 'ids.dart';
import 'target_repository.dart';
import 'task_repository.dart';

/// A code that already resolves to a different, live target.
///
/// One physical code means one target (ADR 0008), so binding a barcode that is
/// already spoken for is refused rather than quietly taken over (#10). It is an
/// exception rather than a returned outcome because every caller of
/// [BindingRepository.bindUnclaimed] wants the binding and none of them has a
/// sensible second plan.
class BindingConflict implements Exception {
  const BindingConflict({
    required this.kind,
    required this.value,
    required this.boundTo,
  });

  final BindingKind kind;

  /// The code, as it would have been stored.
  final String value;

  /// The target it already resolves to.
  final Target boundTo;

  /// What to tell somebody holding the thing.
  ///
  /// It names the target rather than saying "already bound", because the only
  /// way out is to go there: the code is on a product they can see, and which
  /// target it currently points at is the fact they are missing.
  String get message =>
      'That ${kind.displayLabel.toLowerCase()} is already bound to '
      '${boundTo.name}. One code resolves to one target, so unbind it there, '
      'or point it at this one from ${boundTo.name}.';

  @override
  String toString() => 'BindingConflict($message)';
}

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

  /// Provisioning a code is a change the other device has to see — a label
  /// printed here has to resolve there (#12) — so every write below queues the
  /// binding row for push. `(kind, value)` is unique including tombstones, so
  /// what is pushed is always the same row re-pointed rather than a second one
  /// the far device would have to choose between.
  late final OutboxStore _outbox = OutboxStore(_db);

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
        await _outbox.enqueue(
          _db.bindings.actualTableName,
          existing.id,
          now: timestamp,
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
      await _outbox.enqueue(
        _db.bindings.actualTableName,
        binding.id,
        now: timestamp,
      );
      return binding;
    });
  }

  /// Binds [value] to [targetId], unless the code is already spoken for.
  ///
  /// The counterpart to [bind], which re-points on purpose. Re-pointing is the
  /// right answer when somebody is looking at a code they already own and says
  /// "this one means the back door now"; it is the wrong answer when a code is
  /// bound by scanning it, because a barcode quietly changing which target it
  /// resolves to is a binding lost without anybody being told (#10). So
  /// provisioning by scan comes through here, and the repoint action does not.
  ///
  /// Throws [BindingConflict] when a live binding for `(kind, value)` names a
  /// different target that this device can see. A binding whose target it
  /// cannot see is deliberately not a conflict: a dangling reference is an
  /// application-level unassignment (ADR 0011), and re-binding is the one
  /// action that helps.
  Future<Binding> bindUnclaimed({
    required String targetId,
    required BindingKind kind,
    required String value,
    DateTime? now,
  }) async {
    final trimmed = value.trim();
    return _db.transaction(() async {
      final existing = await findBinding(kind, trimmed);
      if (existing != null && existing.targetId != targetId) {
        final claimant =
            await (_db.select(_db.targets)..where(
                  (t) => t.id.equals(existing.targetId) & t.deletedAt.isNull(),
                ))
                .getSingleOrNull();
        if (claimant != null) {
          throw BindingConflict(
            kind: kind,
            value: trimmed,
            boundTo: Target(
              id: claimant.id,
              name: claimant.name,
              description: claimant.description,
              createdAt: claimant.createdAt,
              updatedAt: claimant.updatedAt,
            ),
          );
        }
      }
      return bind(targetId: targetId, kind: kind, value: trimmed, now: now);
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
    await _outbox.enqueue(_db.bindings.actualTableName, id, now: timestamp);
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
