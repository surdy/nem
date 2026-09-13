import 'package:nem/src/sync/sync_cursor.dart';
import 'package:nem/src/sync/sync_row.dart';
import 'package:nem/src/sync/sync_transport.dart';

/// A Supabase project in a map.
///
/// The seam `SyncEngine` is written against, standing in for the real one the
/// way `FakeDigestNotifier` stands in for the notification plugin and
/// `FakeTagGateway` for NFC hardware.
///
/// It is a *model* of PostgREST and not merely a stub, on two points that
/// matter:
///
/// * [updateIfSuperseded] decides whether to write by calling the same
///   `localSupersedes` the real transport encodes into its filters, so a change
///   to the conflict rule cannot pass here and fail there;
/// * [insertRow] raises [RemoteRowExists] on a primary key that is taken, which
///   is the 23505 the real one translates.
///
/// What it deliberately does not model is the network. Requests fail when a
/// test says so, not when a socket does.
class FakeSyncTransport implements SyncTransport {
  /// table -> id -> row, in PostgREST's JSON shape.
  final Map<String, Map<String, Map<String, Object?>>> tables = {};

  /// Set to make every request fail, as an unreachable backend does.
  SyncTransportFailure? failure;

  /// Fail only once this many writes have gone through — a drain that dies
  /// halfway.
  int? failAfterWrites;

  /// Fail only once this many pages of *one table* have been fetched — a pull
  /// that dies between pages. Counted per table, because the engine now walks
  /// four of them in one pull and "the second page" means the second page of
  /// the table under test, not the sixth request of the sweep.
  int? failAfterFetches;

  /// Run before each write, so a test can have the other device change
  /// something mid-drain.
  void Function()? beforeWrite;

  int fetches = 0;
  int updates = 0;
  int inserts = 0;
  int writes = 0;

  /// Pages fetched per table. A pull sweeps every registered table, so the
  /// total says nothing about whether one table's cursor advanced; this is
  /// what the paging assertions are made against.
  final Map<String, int> fetchesByTable = {};

  int fetchesFor(String table) => fetchesByTable[table] ?? 0;

  /// The clock column each table is compared on, so the fake can rank rows the
  /// way the server would.
  final Map<String, String> clockColumns = {};

  Map<String, Map<String, Object?>> _table(String table) =>
      tables.putIfAbsent(table, () => {});

  /// Puts a row in as if the other device had pushed it.
  void seed(String table, Map<String, Object?> row) {
    _table(table)['${row['id']}'] = Map<String, Object?>.from(row);
  }

  Map<String, Object?>? row(String table, String id) => tables[table]?[id];

  @override
  Future<List<Map<String, Object?>>> fetchChanges({
    required String table,
    required String clockColumn,
    required SyncCursor? after,
    required int limit,
  }) async {
    _maybeFail(fetchedTable: table);
    fetches++;
    fetchesByTable.update(table, (n) => n + 1, ifAbsent: () => 1);
    clockColumns[table] = clockColumn;

    final rows = [
      for (final row in _table(table).values) _asSyncRow(row, clockColumn),
    ]..sort(compareBySyncOrder);

    final visible = after == null
        ? rows
        : [
            for (final row in rows)
              if (after.isBefore(row)) row,
          ];
    return [
      for (final row in visible.take(limit))
        Map<String, Object?>.from(row.values),
    ];
  }

  @override
  Future<int> updateIfSuperseded({
    required String table,
    required String clockColumn,
    required SyncRow row,
  }) async {
    _maybeFail();
    updates++;
    clockColumns[table] = clockColumn;
    beforeWrite?.call();

    final existing = _table(table)[row.id];
    if (existing == null) return 0;
    if (!localSupersedes(
      local: row,
      remote: _asSyncRow(existing, clockColumn),
    )) {
      return 0;
    }
    writes++;
    _table(table)[row.id] = Map<String, Object?>.from(row.values);
    return 1;
  }

  @override
  Future<void> insertRow({
    required String table,
    required Map<String, Object?> row,
  }) async {
    _maybeFail();
    inserts++;
    beforeWrite?.call();

    final id = '${row['id']}';
    if (_table(table).containsKey(id)) throw RemoteRowExists(table, id);
    writes++;
    _table(table)[id] = Map<String, Object?>.from(row);
  }

  void _maybeFail({String? fetchedTable}) {
    final failure = this.failure;
    if (failure == null) return;
    if (fetchedTable != null) {
      final pages = failAfterFetches;
      if (pages != null && fetchesFor(fetchedTable) < pages) return;
    } else {
      final threshold = failAfterWrites;
      if (threshold != null && writes < threshold) return;
    }
    throw failure;
  }

  SyncRow _asSyncRow(Map<String, Object?> row, String clockColumn) => SyncRow(
    id: row['id']! as String,
    clock: DateTime.parse(row[clockColumn]! as String).toUtc(),
    deletedAt: row['deleted_at'] == null
        ? null
        : DateTime.parse(row['deleted_at']! as String).toUtc(),
    values: row,
  );
}
