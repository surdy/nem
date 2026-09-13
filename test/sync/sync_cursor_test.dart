import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/sync/sync_cursor.dart';
import 'package:nem/src/sync/sync_row.dart';

SyncRow row(String id, DateTime clock) =>
    SyncRow(id: id, clock: clock, deletedAt: null, values: {'id': id});

void main() {
  final at = DateTime.utc(2026, 6, 15, 9, 30);

  group('encoding', () {
    test('round-trips through the stored form', () {
      final cursor = SyncCursor(clock: at, id: 'task-1');
      expect(SyncCursor.tryParse(cursor.encode()), cursor);
    });

    test('an id containing the separator survives, because the split is from '
        'the right', () {
      final cursor = SyncCursor(clock: at, id: 'a|b|c');
      expect(SyncCursor.tryParse(cursor.encode())?.id, 'a|b|c');
    });

    test('an unreadable cursor is no cursor rather than an exception', () {
      // A full re-pull is slow; refusing to sync because one `sync_state` row
      // is malformed is worse.
      expect(SyncCursor.tryParse(null), isNull);
      expect(SyncCursor.tryParse(''), isNull);
      expect(SyncCursor.tryParse('not-a-date|task-1'), isNull);
      expect(SyncCursor.tryParse('${at.toIso8601String()}|'), isNull);
      expect(SyncCursor.tryParse('|task-1'), isNull);
    });

    test('a cursor written in a local zone is stored in UTC', () {
      final local = DateTime(2026, 6, 15, 9, 30);
      expect(
        SyncCursor(clock: local, id: 'task-1').encode(),
        '${local.toUtc().toIso8601String()}|task-1',
      );
    });
  });

  group('ordering', () {
    test('rows sharing a timestamp are ordered by id', () {
      final rows = [row('c', at), row('a', at), row('b', at)]
        ..sort(compareBySyncOrder);
      expect([for (final r in rows) r.id], ['a', 'b', 'c']);
    });

    test('a row is after the cursor only if it is strictly after the pair', () {
      final cursor = SyncCursor(clock: at, id: 'b');

      // Same timestamp, later id: the rest of the group the page stopped in.
      expect(cursor.isBefore(row('c', at)), isTrue);
      // Same timestamp, earlier id: already applied.
      expect(cursor.isBefore(row('a', at)), isFalse);
      // The cursor row itself is not re-read, which is what a `>=` on the
      // timestamp alone would do forever.
      expect(cursor.isBefore(row('b', at)), isFalse);
      expect(
        cursor.isBefore(row('a', at.add(const Duration(seconds: 1)))),
        isTrue,
      );
      expect(
        cursor.isBefore(row('z', at.subtract(const Duration(seconds: 1)))),
        isFalse,
      );
    });
  });

  test('the PostgREST filter asks for exactly "strictly after the pair"', () {
    final filter = SyncCursor(
      clock: at,
      id: 'task-1',
    ).asPostgrestFilter('updated_at');
    expect(
      filter,
      'updated_at.gt."2026-06-15T09:30:00.000Z",'
      'and(updated_at.eq."2026-06-15T09:30:00.000Z",id.gt."task-1")',
    );
  });
}
