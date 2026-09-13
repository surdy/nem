import 'package:drift/drift.dart';

import '../data/database.dart';
import 'synced_table.dart';

/// Reads and writes whole rows of any registered table, by column name.
///
/// The repositories are the way to touch a task: they know what a schedule is,
/// what a derived cache is and when to recompute one. Sync is the one caller
/// that must *not* know — it moves opaque rows of whichever tables are
/// registered, which is the difference between #12 adding completions, targets
/// and bindings by listing them and adding them by writing three more
/// repositories' worth of push and pull.
///
/// Everything goes through drift's `customSelect` / `customInsert` /
/// `customUpdate` with the table declared in `readsFrom` / `updates`, so a
/// pulled row invalidates exactly the streams that watch it and the due list
/// redraws itself. A raw `customStatement` would write the same bytes and leave
/// the UI showing the old ones until something else happened to touch the
/// table.
class LocalRows {
  LocalRows(this._db);

  final NemDatabase _db;

  SqlTypes get types => _db.typeMapping;

  /// One row as raw SQLite values, or null if there is none.
  ///
  /// Tombstoned rows are included, deliberately: sync needs to see that a row
  /// was deleted, and a `deleted_at` filter here would make a local tombstone
  /// look like a row that never existed and let the remote copy resurrect it.
  Future<Map<String, Object?>?> read(SyncedTable table, String id) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM "${table.name}" WHERE "id" = ?',
          variables: [Variable<String>(id)],
          readsFrom: {table.info},
        )
        .get();
    return rows.isEmpty ? null : rows.single.data;
  }

  /// Every id in the table, oldest row first — what seeding the outbox walks.
  Future<List<String>> ids(SyncedTable table) async {
    final rows = await _db
        .customSelect(
          'SELECT "id" FROM "${table.name}" ORDER BY "created_at", "id"',
          readsFrom: {table.info},
        )
        .get();
    return [for (final row in rows) row.read<String>('id')];
  }

  /// Inserts a row that is not there yet.
  Future<void> insert(SyncedTable table, Map<String, Object?> values) async {
    final columns = values.keys.toList();
    await _db.customInsert(
      'INSERT INTO "${table.name}" '
      '(${columns.map((c) => '"$c"').join(', ')}) '
      'VALUES (${List.filled(columns.length, '?').join(', ')})',
      variables: [
        for (final column in columns)
          _variable(table.column(column), values[column]),
      ],
      updates: {table.info},
    );
  }

  /// Overwrites the columns of an existing row.
  ///
  /// An `UPDATE` rather than an `INSERT OR REPLACE`, and not as a matter of
  /// taste: SQLite implements `REPLACE` as a delete followed by an insert, and
  /// with `PRAGMA foreign_keys = ON` — which `NemDatabase` sets on every open —
  /// that delete is refused by any child row pointing at it. Replacing a task
  /// that has completions would fail, and replacing one that has none would
  /// work, so the bug would only appear on rows with history.
  Future<void> update(
    SyncedTable table,
    String id,
    Map<String, Object?> values,
  ) async {
    final columns = values.keys.where((c) => c != 'id').toList();
    if (columns.isEmpty) return;
    await _db.customUpdate(
      'UPDATE "${table.name}" SET '
      '${columns.map((c) => '"$c" = ?').join(', ')} '
      'WHERE "id" = ?',
      variables: [
        for (final column in columns)
          _variable(table.column(column), values[column]),
        Variable<String>(id),
      ],
      updates: {table.info},
      updateKind: UpdateKind.update,
    );
  }

  /// A bound variable of the right SQL type for a raw column value.
  ///
  /// The values here are already in SQLite's own representation — a `DateTime`
  /// is the integer drift stored, a `bool` is 0 or 1 — so they bind as the
  /// primitive they are rather than as the Dart type the column reads back as.
  static Variable<Object> _variable(
    GeneratedColumn<Object> column,
    Object? value,
  ) {
    return switch (column.type) {
      DriftSqlType.string => Variable<String>(value as String?),
      DriftSqlType.double => Variable<double>((value as num?)?.toDouble()),
      DriftSqlType.blob => Variable<Uint8List>(value as Uint8List?),
      // int, bool and dateTime are all integers on disk.
      _ => Variable<int>((value as num?)?.toInt()),
    };
  }
}
