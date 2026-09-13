import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/sync/supabase_sync_transport.dart';
import 'package:nem/src/sync/sync_row.dart';

/// The PostgREST half of the conflict rule.
///
/// `SyncEngine` is tested against `FakeSyncTransport`, which decides by calling
/// `localSupersedes` directly. The real transport cannot: it has to hand
/// Postgres a filter and let Postgres decide, and that translation is the one
/// place the two halves could quietly disagree. This checks the string.
void main() {
  final at = DateTime.utc(2026, 6, 15, 9);

  SyncRow row({DateTime? deletedAt}) =>
      SyncRow(id: 'task-1', clock: at, deletedAt: deletedAt, values: const {});

  test('a live row may only overwrite an older live row', () {
    expect(
      postgrestPrecedenceFilter(clockColumn: 'updated_at', row: row()),
      'and(deleted_at.is.null,updated_at.lt."2026-06-15T09:00:00.000Z")',
    );
  });

  test('a tombstone may overwrite any live row, or an older tombstone', () {
    expect(
      postgrestPrecedenceFilter(
        clockColumn: 'updated_at',
        row: row(deletedAt: at),
      ),
      'deleted_at.is.null,updated_at.lt."2026-06-15T09:00:00.000Z"',
    );
  });

  test('the clock column is whatever the table names', () {
    // Every registered table names `updated_at` today, but the column is a
    // property of the table (`SyncedTable.clockColumn`) and the filter has to
    // follow whatever it says.
    expect(
      postgrestPrecedenceFilter(clockColumn: 'created_at', row: row()),
      contains('created_at.lt.'),
    );
  });

  test('the timestamp is quoted, because an `or` splits on commas', () {
    expect(
      postgrestPrecedenceFilter(clockColumn: 'updated_at', row: row()),
      contains('"2026-06-15T09:00:00.000Z"'),
    );
  });

  test('a clock in a local zone is sent as UTC', () {
    final local = DateTime(2026, 6, 15, 9);
    expect(
      postgrestPrecedenceFilter(
        clockColumn: 'updated_at',
        row: SyncRow(
          id: 'task-1',
          clock: local,
          deletedAt: null,
          values: const {},
        ),
      ),
      contains('"${local.toUtc().toIso8601String()}"'),
    );
  });
}
