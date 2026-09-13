import 'package:drift/drift.dart';

import '../data/database.dart';
import 'photo.dart';

/// The queue of bytes waiting for a network.
///
/// The sibling of `OutboxStore`, and deliberately not the same thing — the
/// argument for two queues is on the `PhotoTransfers` table in
/// `data/database.dart`. What they share is the shape that makes offline work:
/// a row in SQLite, so the queue survives a restart; an attempt count and the
/// last error, so work that can never be done is visible rather than silent;
/// and a drain that takes entries oldest-first and leaves the one that failed
/// exactly where it was.
class PhotoTransferQueue {
  PhotoTransferQueue(this._db);

  final NemDatabase _db;

  /// Queues byte work for a photo, or changes what is already queued.
  ///
  /// One entry per photo, so the operations cannot pile up on one image. A
  /// repeat of the same operation keeps the moment it was first queued — the
  /// drain runs in that order, so a photo attached this morning uploads before
  /// one attached this afternoon. A *different* operation replaces it and
  /// starts its attempt count again, which is what makes deleting a photo whose
  /// upload never went out cancel that upload rather than race it.
  Future<void> enqueue(
    String photoId,
    PhotoTransferOperation operation, {
    DateTime? now,
  }) async {
    final existing = await find(photoId);
    if (existing != null && existing.operation == operation) return;
    await _db
        .into(_db.photoTransfers)
        .insertOnConflictUpdate(
          PhotoTransfersCompanion.insert(
            photoId: photoId,
            operation: operation,
            enqueuedAt: now ?? DateTime.now(),
          ),
        );
  }

  /// The queue, oldest first.
  Future<List<PhotoTransfer>> pending({int? limit}) async {
    final query = _db.select(_db.photoTransfers)
      ..orderBy([
        (t) => OrderingTerm(expression: t.enqueuedAt),
        (t) => OrderingTerm(expression: t.photoId),
      ]);
    if (limit != null) query.limit(limit);
    return [for (final row in await query.get()) _toTransfer(row)];
  }

  Future<PhotoTransfer?> find(String photoId) async {
    final row = await (_db.select(
      _db.photoTransfers,
    )..where((t) => t.photoId.equals(photoId))).getSingleOrNull();
    return row == null ? null : _toTransfer(row);
  }

  /// Takes an entry off the queue, because the bytes moved or because there is
  /// nothing left to move.
  Future<void> remove(String photoId) async {
    await (_db.delete(
      _db.photoTransfers,
    )..where((t) => t.photoId.equals(photoId))).go();
  }

  /// Records that a drain tried this entry and failed, leaving it queued.
  ///
  /// Leaving it queued is the point. Issue #15 asks that a failed upload is
  /// "retried and surfaced to the user, never silently dropped", and those are
  /// two halves of one thing: the entry stays so the next drain retries it, and
  /// the message stays so the task screen can say what went wrong while it
  /// waits.
  Future<void> recordFailure(String photoId, String message) async {
    final existing = await find(photoId);
    if (existing == null) return;
    await (_db.update(
      _db.photoTransfers,
    )..where((t) => t.photoId.equals(photoId))).write(
      PhotoTransfersCompanion(
        attempts: Value(existing.attempts + 1),
        lastError: Value(message),
      ),
    );
  }

  Future<int> count() async =>
      (await _db.select(_db.photoTransfers).get()).length;

  /// How many photos are waiting on a network, live — what the settings screen
  /// shows next to the outbox's own count.
  Stream<int> watchCount() =>
      _db.select(_db.photoTransfers).watch().map((rows) => rows.length);

  static PhotoTransfer _toTransfer(PhotoTransferRow row) => PhotoTransfer(
    photoId: row.photoId,
    operation: row.operation,
    enqueuedAt: row.enqueuedAt,
    attempts: row.attempts,
    lastError: row.lastError,
  );
}
