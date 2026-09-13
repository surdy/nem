import 'sync_row.dart';

/// How far a table's pull has got: the last row it applied, as the pair
/// `(clock, id)`.
///
/// ## Why the id is in here
///
/// The obvious cursor is "the newest `updated_at` I have seen", pulled back
/// with `updated_at > cursor`. It has a hole, and the hole is not exotic:
/// create three tasks in one batch and Postgres can easily stamp two of them
/// with the same microsecond. If a page ends in the middle of such a group, a
/// `>` cursor skips the rest of the group; a `>=` cursor re-reads the group
/// forever and, once the group is bigger than one page, never advances at all.
/// The pull makes no progress and the two devices never converge, with nothing
/// in the logs but a request that keeps returning the same rows.
///
/// Ordering by `(clock, id)` and remembering both halves removes the ambiguity:
/// the id is unique, so the pair is a total order over the rows, and "strictly
/// after this pair" is always exactly the rest of them. That is the same
/// keyset pagination any cursored API uses, and it is why [asPostgrestFilter]
/// is an `or(...)` rather than a `gt`.
class SyncCursor {
  const SyncCursor({required this.clock, required this.id});

  /// The clock column of the last row applied.
  final DateTime clock;

  /// Its id, which breaks ties within the same clock value.
  final String id;

  /// The cursor that would be stored after applying [row].
  factory SyncCursor.after(SyncRow row) =>
      SyncCursor(clock: row.clock.toUtc(), id: row.id);

  /// Parses the stored form, or gives up.
  ///
  /// An unreadable cursor falls back to null — a full re-pull — rather than
  /// throwing. Re-pulling is merely slow, and every row it re-applies either
  /// loses to the local copy or is identical to it; refusing to sync at all
  /// because one `sync_state` value is malformed is the worse failure.
  static SyncCursor? tryParse(String? stored) {
    if (stored == null) return null;
    final separator = stored.indexOf('|');
    if (separator <= 0 || separator == stored.length - 1) return null;
    final clock = DateTime.tryParse(stored.substring(0, separator));
    if (clock == null) return null;
    return SyncCursor(
      clock: clock.toUtc(),
      id: stored.substring(separator + 1),
    );
  }

  /// The stored form. Split on the *first* separator: an ISO-8601 timestamp
  /// never contains one, and a row id — which is somebody else's format once
  /// rows arrive from another device — may contain any number.
  String encode() => '${clock.toUtc().toIso8601String()}|$id';

  /// The PostgREST filter for "strictly after this cursor", given the clock
  /// column's name.
  ///
  /// `clock > c OR (clock = c AND id > i)`. Values are double-quoted because a
  /// PostgREST `or` splits on commas and an unquoted timestamp is only safe by
  /// luck.
  String asPostgrestFilter(String clockColumn) {
    final at = clock.toUtc().toIso8601String();
    return '$clockColumn.gt."$at",'
        'and($clockColumn.eq."$at",id.gt."$id")';
  }

  /// Whether [row] is strictly after this cursor — the same comparison
  /// [asPostgrestFilter] asks Postgres for, so a fake can be held to it.
  bool isBefore(SyncRow row) {
    final rowClock = row.clock.toUtc();
    if (rowClock.isAfter(clock)) return true;
    if (rowClock.isBefore(clock)) return false;
    return row.id.compareTo(id) > 0;
  }

  @override
  bool operator ==(Object other) =>
      other is SyncCursor &&
      other.clock.isAtSameMomentAs(clock) &&
      other.id == id;

  @override
  int get hashCode => Object.hash(clock.toUtc(), id);

  @override
  String toString() => 'SyncCursor(${encode()})';
}

/// Orders rows the way the pull reads them: by clock, then by id.
int compareBySyncOrder(SyncRow a, SyncRow b) {
  final byClock = a.clock.toUtc().compareTo(b.clock.toUtc());
  return byClock != 0 ? byClock : a.id.compareTo(b.id);
}
