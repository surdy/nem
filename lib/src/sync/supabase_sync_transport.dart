import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_cursor.dart';
import 'sync_row.dart';
import 'sync_transport.dart';

/// Postgres' unique-violation `SQLSTATE`, which is what a PostgREST insert
/// returns when the primary key is already taken.
const _uniqueViolation = '23505';

/// `localSupersedes` (see `sync_row.dart`) written as a PostgREST `or` filter.
///
/// The two halves have to say the same thing, and this is the one place they
/// could silently stop doing so — which is why it is a pure function returning
/// a string a test can read, rather than a chain of builder calls inside a
/// request.
///
/// * A live row may overwrite only a live row with an older clock.
///   `deleted_at.is.null` is what stops a rename written on a phone that was
///   offline from undoing a delete, and `lt` rather than `lte` is the tie going
///   to whatever is already there.
/// * A tombstone may overwrite any live row whatever its clock, or an older
///   tombstone.
String postgrestPrecedenceFilter({
  required String clockColumn,
  required SyncRow row,
}) {
  // Quoted because PostgREST splits an `or` on commas, and an ISO-8601
  // timestamp is only comma-free by luck.
  final clock = '"${row.clock.toUtc().toIso8601String()}"';
  return row.isDeleted
      ? 'deleted_at.is.null,$clockColumn.lt.$clock'
      : 'and(deleted_at.is.null,$clockColumn.lt.$clock)';
}

/// The only implementation of [SyncTransport]: `supabase_flutter`, spoken to
/// directly (ADR 0002).
///
/// Nothing in this file decides anything. It holds a [SupabaseClient] handed to
/// it by whoever owns the session, turns three requests into three PostgREST
/// calls, and translates errors. There is no repository, no DTO, no mapper and
/// no second backend behind a flag — the base URL and the anon key are settings
/// fields, and pointing them at a self-hosted instance is the whole of the
/// "swap backend" story.
class SupabaseSyncTransport implements SyncTransport {
  const SupabaseSyncTransport(this.client);

  final SupabaseClient client;

  @override
  Future<List<Map<String, Object?>>> fetchChanges({
    required String table,
    required String clockColumn,
    required SyncCursor? after,
    required int limit,
  }) {
    return _guard(() async {
      var query = client.from(table).select();
      if (after != null) {
        query = query.or(after.asPostgrestFilter(clockColumn));
      }
      final rows = await query
          // The `(clock, id)` keyset order the cursor is built on. Ordering by
          // the clock alone would make the page boundary ambiguous whenever two
          // rows share a timestamp — see [SyncCursor].
          .order(clockColumn, ascending: true)
          .order('id', ascending: true)
          .limit(limit);
      return [for (final row in rows) Map<String, Object?>.from(row)];
    });
  }

  /// `PATCH /<table>?id=eq.<id>&<the precedence filters>`.
  ///
  /// The filters are `localSupersedes` (see `sync_row.dart`) written in
  /// PostgREST, and they have to stay in step with it:
  ///
  /// * pushing a live row overwrites only a live row with an older clock —
  ///   `deleted_at=is.null` keeps a tombstone from being undone, and
  ///   `<clock>=lt.<ours>` is last-write-wins with the tie going to whatever is
  ///   already there;
  /// * pushing a tombstone overwrites any live row whatever its clock, and an
  ///   older tombstone — `or=(deleted_at.is.null,<clock>.lt.<ours>)`.
  ///
  /// Doing it as a conditional `PATCH` rather than as a read, a comparison and
  /// a write is what makes it safe with two devices pushing at once: Postgres
  /// evaluates the filter and the write in one statement, so there is no window
  /// between deciding and writing for the other phone to fit into. It is also
  /// why nem needs no server-side trigger to enforce any of this (ADR 0001 —
  /// nothing is computed server-side).
  @override
  Future<int> updateIfSuperseded({
    required String table,
    required String clockColumn,
    required SyncRow row,
  }) {
    return _guard(() async {
      final written = await client
          .from(table)
          .update(row.values)
          .eq('id', row.id)
          .or(postgrestPrecedenceFilter(clockColumn: clockColumn, row: row))
          // `select()` makes PostgREST return the rows it wrote, which is the
          // only way to learn whether the filters matched anything.
          .select();
      return written.length;
    });
  }

  @override
  Future<void> insertRow({
    required String table,
    required Map<String, Object?> row,
  }) {
    return _guard(() async {
      await client.from(table).insert(row);
    }, onUniqueViolation: () => RemoteRowExists(table, '${row['id']}'));
  }

  /// Everything the network or PostgREST can throw, narrowed to the two
  /// outcomes the engine acts on.
  Future<T> _guard<T>(
    Future<T> Function() request, {
    RemoteRowExists Function()? onUniqueViolation,
  }) async {
    try {
      return await request();
    } on PostgrestException catch (error) {
      if (onUniqueViolation != null && error.code == _uniqueViolation) {
        throw onUniqueViolation();
      }
      throw SyncTransportFailure(
        error.message,
        // PostgREST answers an expired or missing token with 401, and a row
        // that RLS hides with 403 — which, with nem's single-account policies,
        // means the signed-in account is not the one the data belongs to.
        isAuthFailure: error.code == '401' || error.code == '403',
      );
    } on AuthException catch (error) {
      throw SyncTransportFailure(error.message, isAuthFailure: true);
    } on Object catch (error) {
      // A socket that will not open, a DNS name that does not resolve, a
      // self-hosted URL with a typo in it. All the same answer: not now.
      throw SyncTransportFailure('$error');
    }
  }
}
