import 'package:drift/drift.dart';

/// A table that takes part in sync, and the translation between how drift
/// stores its rows and how PostgREST sends them.
///
/// Registering a table is the whole of adding it to sync: the outbox, the
/// drain, the pull, the cursor and the merge are all written against this
/// descriptor rather than against `tasks`. #11 registers `tasks`; #12 adds the
/// rest by adding entries to [defaultSyncedTables].
///
/// Nothing here knows what a task *is*. The engine moves rows of columns, and
/// the meaning of those columns stays where it already lives — in the
/// repositories and the domain.
class SyncedTable {
  const SyncedTable(this.info, {this.clockColumn = 'updated_at'});

  /// drift's description of the table: its SQL name, its columns and their
  /// types. Read at runtime so a new column is picked up by regenerating, not
  /// by editing a list here.
  final TableInfo<Table, dynamic> info;

  /// The column both the pull cursor and last-write-wins are measured on.
  ///
  /// `updated_at` for everything mutable. Completions have no `updated_at` —
  /// they are immutable events (ADR 0004) — so #12 will register them on
  /// `created_at`, and the same comparison then degenerates into exactly the
  /// "append and merge, no resolution" ADR 0004 asks for: two copies of one
  /// completion have identical clocks, so neither supersedes the other and
  /// both devices keep the row they already have.
  ///
  /// One thing #12 still has to settle, flagged here rather than discovered
  /// there: tombstoning a completion moves `deleted_at` but not `created_at`,
  /// so a cursor on `created_at` would never carry that tombstone across.
  /// Either completions gain an `updated_at` or the cursor reads the later of
  /// the two columns.
  final String clockColumn;

  String get name => info.actualTableName;

  /// The SQL column names, in the order drift declares them.
  List<String> get columnNames => [for (final c in info.$columns) c.name];

  /// Every synced table carries a soft delete (PLAN.md — Sync), which is what
  /// lets a delete beat a stale update instead of racing it.
  bool get hasSoftDelete => columnNames.contains('deleted_at');

  GeneratedColumn<Object> column(String name) =>
      info.$columns.firstWhere((c) => c.name == name);
}

/// Turns a drift row into the JSON PostgREST expects, and back.
///
/// The conversion is driven by drift's own type mapping rather than by a table
/// of column names: a `DateTime` column is stored by drift as an integer and
/// wanted by Postgres as an ISO-8601 `timestamptz`, and a `bool` is an integer
/// here and a boolean there. Going through [SqlTypes] is what guarantees the
/// round trip matches what drift would have written itself — a hand-rolled
/// `millisecondsSinceEpoch ~/ 1000` would be right until the day drift's
/// storage option changes underneath it.
class SyncCodec {
  const SyncCodec(this.table, this.types);

  final SyncedTable table;
  final SqlTypes types;

  /// A raw SQLite row — the map a `SELECT *` hands back — as PostgREST JSON.
  Map<String, Object?> toRemote(Map<String, Object?> local) {
    return {
      for (final column in table.info.$columns)
        column.name: _toRemoteValue(column, local[column.name]),
    };
  }

  /// PostgREST JSON as the raw SQLite values drift stores.
  ///
  /// Columns the remote does not send are left out rather than written as
  /// null, so a backend running an older migration cannot blank a column this
  /// build added.
  Map<String, Object?> toLocal(Map<String, Object?> remote) {
    return {
      for (final column in table.info.$columns)
        if (remote.containsKey(column.name))
          column.name: _toLocalValue(column, remote[column.name]),
    };
  }

  /// Reads a `DateTime` out of either shape.
  DateTime? readTime(Map<String, Object?> remote, String columnName) {
    final value = remote[columnName];
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    if (value is int) {
      return types.read(DriftSqlType.dateTime, value)?.toUtc();
    }
    throw FormatException('$columnName is not a timestamp', value);
  }

  Object? _toRemoteValue(GeneratedColumn<Object> column, Object? value) {
    if (value == null) return null;
    return switch (column.type) {
      DriftSqlType.dateTime =>
        types.read(DriftSqlType.dateTime, value)!.toUtc().toIso8601String(),
      DriftSqlType.bool => types.read(DriftSqlType.bool, value),
      _ => value,
    };
  }

  Object? _toLocalValue(GeneratedColumn<Object> column, Object? value) {
    if (value == null) return null;
    return switch (column.type) {
      DriftSqlType.dateTime => types.mapToSqlVariable(
        value is DateTime ? value : DateTime.parse(value as String).toUtc(),
      ),
      DriftSqlType.bool => types.mapToSqlVariable(
        value is bool ? value : value != 0,
      ),
      // Postgres hands back `int` as `int` and `numeric` as `num`; JSON has no
      // integer type of its own, so a whole number can arrive as a double.
      DriftSqlType.int => (value as num).toInt(),
      DriftSqlType.double => (value as num).toDouble(),
      _ => value,
    };
  }
}
