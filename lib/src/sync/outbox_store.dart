import 'package:drift/drift.dart';

import '../data/database.dart';

/// One row waiting to be pushed.
class OutboxEntry {
  const OutboxEntry({
    required this.table,
    required this.rowId,
    required this.enqueuedAt,
    required this.attempts,
    this.lastError,
  });

  final String table;
  final String rowId;
  final DateTime enqueuedAt;
  final int attempts;
  final String? lastError;

  @override
  String toString() => 'OutboxEntry($table/$rowId, attempts: $attempts)';
}

/// The queue of local changes waiting for a network (PLAN.md — Sync).
///
/// Device-local and never synced: what this device still owes the server is
/// nobody else's business.
class OutboxStore {
  OutboxStore(this._db);

  final NemDatabase _db;

  /// Marks a row as changed here and not yet pushed.
  ///
  /// Idempotent, and deliberately does not bump [OutboxEntry.enqueuedAt] on a
  /// row that is already queued: the drain runs in enqueue order, and keeping
  /// the *first* time a row went dirty is what stops a task that is edited
  /// repeatedly from being pushed after a completion recorded against it.
  ///
  /// Called from the repositories, on the write path, rather than from a SQLite
  /// trigger. A trigger could not have been forgotten — but it also fires on
  /// the writes a *pull* makes, which would queue every row the other device
  /// just sent straight back at it, and suppressing that needs a flag the
  /// trigger reads, which is more moving parts than the one line this is.
  Future<void> enqueue(String table, String rowId, {DateTime? now}) async {
    await _db
        .into(_db.outbox)
        .insert(
          OutboxCompanion.insert(
            pendingTable: table,
            rowId: rowId,
            enqueuedAt: now ?? DateTime.now(),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  /// The queue, oldest first.
  Future<List<OutboxEntry>> pending({int? limit}) async {
    final query = _db.select(_db.outbox)
      ..orderBy([
        (o) => OrderingTerm(expression: o.enqueuedAt),
        (o) => OrderingTerm(expression: o.pendingTable),
        (o) => OrderingTerm(expression: o.rowId),
      ]);
    if (limit != null) query.limit(limit);
    return [for (final row in await query.get()) _toEntry(row)];
  }

  /// Takes an entry off the queue, because it is pushed or because there is
  /// nothing left to push.
  Future<void> remove(String table, String rowId) async {
    await (_db.delete(
      _db.outbox,
    )..where((o) => o.pendingTable.equals(table) & o.rowId.equals(rowId))).go();
  }

  /// Records that a drain tried this entry and failed, leaving it queued.
  Future<void> recordFailure(String table, String rowId, String message) async {
    await (_db.update(_db.outbox)
          ..where((o) => o.pendingTable.equals(table) & o.rowId.equals(rowId)))
        .write(
          OutboxCompanion(
            attempts: Value(await _attempts(table, rowId) + 1),
            lastError: Value(message),
          ),
        );
  }

  Future<int> count() async {
    final rows = await _db.select(_db.outbox).get();
    return rows.length;
  }

  /// Whether a row is still waiting to be pushed.
  ///
  /// Asked by the photo queue, which may not delete an object from Storage
  /// until the tombstone that justifies it has actually gone up — see
  /// `PhotoSync.drain`. Nothing in the outbox's own drain needs it.
  Future<bool> holds(String table, String rowId) async =>
      await _attemptsRow(table, rowId) != null;

  /// How many changes are waiting, live — what the settings screen shows.
  Stream<int> watchCount() =>
      _db.select(_db.outbox).watch().map((rows) => rows.length);

  Future<int> _attempts(String table, String rowId) async =>
      (await _attemptsRow(table, rowId))?.attempts ?? 0;

  Future<OutboxRow?> _attemptsRow(String table, String rowId) =>
      (_db.select(
            _db.outbox,
          )..where((o) => o.pendingTable.equals(table) & o.rowId.equals(rowId)))
          .getSingleOrNull();

  OutboxEntry _toEntry(OutboxRow row) => OutboxEntry(
    table: row.pendingTable,
    rowId: row.rowId,
    enqueuedAt: row.enqueuedAt,
    attempts: row.attempts,
    lastError: row.lastError,
  );
}
