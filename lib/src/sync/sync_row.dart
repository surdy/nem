/// One version of one row, reduced to what deciding a conflict needs.
///
/// Pure data. Building one from SQLite or from PostgREST is somebody else's
/// job; everything in this file is a function of these three fields and can be
/// exercised without a database, a network or a Supabase project.
class SyncRow {
  const SyncRow({
    required this.id,
    required this.clock,
    required this.deletedAt,
    required this.values,
  });

  final String id;

  /// The value of the table's clock column — `updated_at` for everything
  /// mutable (see `SyncedTable.clockColumn`).
  final DateTime clock;

  /// The soft delete. Non-null means this version is a tombstone.
  final DateTime? deletedAt;

  /// The row itself, in PostgREST's shape.
  final Map<String, Object?> values;

  bool get isDeleted => deletedAt != null;

  @override
  String toString() =>
      'SyncRow($id @ ${clock.toIso8601String()}${isDeleted ? ' deleted' : ''})';
}

/// Whether [remote] supersedes [local] — the whole of nem's conflict
/// resolution, in one function, for one row.
///
/// Three rules, in order:
///
/// 1. **Nothing local.** The remote row is news; take it. This is also how a
///    task created on the other phone arrives.
///
/// 2. **A tombstone wins, whatever its timestamp.** A soft delete is not just
///    another edit with a later `updated_at` — it outranks every non-deleted
///    version of the row. PLAN.md puts it as "deletes are soft so a delete
///    beats a stale update", and the update that loses is *always* stale in the
///    sense that matters: the device that wrote it had not seen the delete.
///    Plain last-write-wins would let a phone that was offline while you
///    deleted a task resurrect it by renaming it, which is both the surprising
///    outcome and the unrecoverable one — there is no undelete in nem, so a
///    resurrected row can only be deleted again, whereas a lost rename can be
///    retyped. Two tombstones fall through to rule 3, where the earlier delete
///    simply stands.
///
/// 3. **Last write wins on the clock column**, and a tie goes to the remote.
///    The tie-break has to be a rule rather than a coin toss or the two devices
///    never converge: whoever keeps their own copy on a tie keeps it forever,
///    because the loser's push is refused by the same comparison. Sending both
///    devices to the same arbiter — the row the server already holds — makes
///    the tie converge in one round. In practice a tie means one device pulled
///    a row and is pushing it straight back, and taking the remote copy of a
///    row it is identical to costs nothing.
bool remoteSupersedes({SyncRow? local, required SyncRow remote}) {
  if (local == null) return true;
  if (local.isDeleted != remote.isDeleted) return remote.isDeleted;
  return !remote.clock.isBefore(local.clock);
}

/// Whether pushing [local] may overwrite [remote] — the mirror of
/// [remoteSupersedes], and deliberately defined as its negation rather than as
/// a second copy of the rules.
///
/// `SupabaseSyncTransport` has to express this as PostgREST filters on a
/// `PATCH`, which is the one place the two halves could drift apart; writing it
/// here as `!remoteSupersedes` is what makes "the push and the pull agree" a
/// property a test can assert rather than a comment nobody rereads.
bool localSupersedes({required SyncRow local, SyncRow? remote}) {
  if (remote == null) return true;
  return !remoteSupersedes(local: local, remote: remote);
}
