import 'sync_cursor.dart';
import 'sync_row.dart';

/// The three HTTP requests sync makes, and nothing else.
///
/// ## This is a testing seam, not a backend abstraction
///
/// ADR 0002 says there is deliberately no repository or gateway layer wrapping
/// Supabase, and not to add one "for flexibility" — the flexibility lives in
/// the URL field. This is the other thing: the same narrow seam
/// `DigestNotifier` is for the notification plugin and `TagGateway` is for NFC.
/// The test is what is on each side of the line.
///
/// * Below it — [SupabaseSyncTransport], the only implementation — is three
///   methods of `supabase_flutter` calls with no translation, no retry, no
///   caching and no decisions. It is not a portability layer and there will
///   never be a second one; a self-hosted instance is reached by changing the
///   URL, exactly as the ADR intends.
/// * Above it is every decision sync makes — what to enqueue, which version of
///   a row stands, how a delete races an update, how far the cursor moves, what
///   a half-drained outbox leaves behind. None of that is Supabase's, all of it
///   is where nem's bugs will be, and this seam is what lets it be unit-tested
///   on a laptop with no Docker, no Supabase CLI and no project.
///
/// The difference matters if someone later wants to "finish the abstraction".
/// There is nothing to finish. Widening this interface to hide PostgREST would
/// be the layer ADR 0002 rejects; it is deliberately shaped *like* PostgREST —
/// a filtered GET, a filtered PATCH, a POST — so that it cannot quietly become
/// one.
abstract class SyncTransport {
  /// The rows of [table] strictly after [after], in `(clock, id)` order, at
  /// most [limit] of them.
  ///
  /// One page. Paging is the engine's job, because knowing when to stop is a
  /// decision and this is not where decisions live.
  Future<List<Map<String, Object?>>> fetchChanges({
    required String table,
    required String clockColumn,
    required SyncCursor? after,
    required int limit,
  });

  /// Overwrites the remote copy of [row], but only where [row] supersedes what
  /// is already there.
  ///
  /// The condition is `localSupersedes` expressed as PostgREST filters — see
  /// [SupabaseSyncTransport.updateIfSuperseded] for the mapping. Returns the
  /// number of rows written: 0 means either that no such row exists or that the
  /// remote copy stands, and the caller cannot tell which from this alone.
  Future<int> updateIfSuperseded({
    required String table,
    required String clockColumn,
    required SyncRow row,
  });

  /// Inserts [row], which must not already exist.
  ///
  /// Throws [RemoteRowExists] when it does. That is the only outcome worth
  /// distinguishing: it means another device got there first, and the answer is
  /// always the same — leave the remote copy alone and let the next pull bring
  /// it down.
  Future<void> insertRow({
    required String table,
    required Map<String, Object?> row,
  });
}

/// An insert lost a race with a row that is already there — Postgres 23505.
class RemoteRowExists implements Exception {
  const RemoteRowExists(this.table, this.id);

  final String table;
  final String id;

  @override
  String toString() => 'RemoteRowExists($table/$id)';
}

/// The backend could not be reached, or refused the request.
///
/// Everything that is not [RemoteRowExists] arrives as this: sync cannot tell a
/// flat battery on the router from an expired token from a policy that says no,
/// and it does the same thing in all three cases — stop, keep the outbox, try
/// again later.
class SyncTransportFailure implements Exception {
  const SyncTransportFailure(this.message, {this.isAuthFailure = false});

  final String message;

  /// Whether the backend said "not you" rather than "not now". Surfaced so the
  /// settings screen can say "sign in again" instead of "no connection".
  final bool isAuthFailure;

  @override
  String toString() => 'SyncTransportFailure($message)';
}
