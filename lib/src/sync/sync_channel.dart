/// A subscription to "the backend changed", and nothing more than that.
///
/// ## Why nothing crosses this seam but a signal
///
/// Supabase's Postgres Changes hands a subscriber the whole row — the same JSON
/// `SyncTransport.fetchChanges` returns — and writing it straight into SQLite is
/// the obvious implementation and the wrong one. Three things are true of a
/// socket that are not true of a cursored pull:
///
/// * **It delivers the same row twice.** A completion the other phone wrote
///   arrives on the socket, and again on the next pull, because the pull filters
///   on the cursor and the cursor has not moved over it. Two paths into the
///   database are two chances to get the merge rule subtly different.
/// * **It misses rows entirely, and never says so.** A subscription that was not
///   open — the app was backgrounded, the socket dropped, the phone was in a
///   lift — is not backfilled on rejoin. A channel has no "since" parameter.
///   Whatever happened while it was away is simply not in the stream.
/// * **It cannot move the cursor.** The cursor is the last `(updated_at, id)`
///   pair *applied* (CONTEXT.md — "Cursor"), and it is sound as a watermark only
///   because the pull walks rows in `(updated_at, id)` order. Realtime delivers
///   in *commit* order, which is nothing like it: a phone that spent a fortnight
///   offline commits its backlog now, stamped a fortnight ago. A cursor advanced
///   over a realtime payload would step forward over rows the peer has not
///   pushed yet, and nothing would ever ask for them again — completions lost
///   silently and permanently, which is the exact failure the applied-not-read
///   rule exists to prevent.
///
/// So realtime is a doorbell, not a delivery. It says "there is post"; the pull
/// is what opens the door; and the merge rule, the cursor and the recompute are
/// the ones that already exist in `SyncEngine` and stay the only things that
/// touch the database. Rows cannot be duplicated by the socket because the
/// socket cannot write, and a gap in it costs nothing, because a payload nem
/// never saw carried no information the cursor does not already imply. The
/// worst a dropped subscription can do is make an update late, and the pull on
/// rejoin — and on foreground, and on the retry timer — is what bounds that.
///
/// It is also why this interface deliberately *cannot* carry a row. Someone
/// arriving to add "just apply the payload, it is right here" has to widen the
/// seam first, and reads this on the way.
///
/// ## This is a testing seam, not a backend abstraction
///
/// The same line `SyncTransport` draws, for the same reason (ADR 0002, and that
/// file's doc comment). Below it, `SupabaseSyncChannel` is one `channel()`, an
/// `onPostgresChanges()` per synced table and a `subscribe()`, with no
/// decisions in between.
/// Above it is the only decision realtime makes — when to ask for a pull — and
/// that is testable on a laptop with no Docker, no Supabase CLI and no project.
abstract class SyncChannel {
  /// Starts listening, calling [onChanged] whenever the backend reports a
  /// change *and* whenever the subscription joins or rejoins.
  ///
  /// The two are deliberately the same signal. A join means the socket was not
  /// listening a moment ago, so anything at all could have changed while it was
  /// not — which is what a payload says too, with more confidence and no more
  /// detail than the pull will establish for itself anyway.
  ///
  /// Never throws. A realtime subscription that cannot be opened leaves a device
  /// that syncs on foreground and on the retry timer, which is every device nem
  /// had before this and is not a failure worth reporting.
  Future<void> open(void Function() onChanged);

  /// Stops listening and lets the socket go.
  Future<void> close();
}
