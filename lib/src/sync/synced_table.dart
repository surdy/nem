import 'package:drift/drift.dart';

/// A table that takes part in sync, and the translation between how drift
/// stores its rows and how PostgREST sends them.
///
/// Registering a table is the whole of adding it to sync: the outbox, the
/// drain, the pull, the cursor and the merge are all written against this
/// descriptor rather than against `tasks`. #11 registered `tasks`; #12 added
/// targets, bindings and completions by adding three entries to
/// `defaultSyncedTables` and nothing else; #14 added categories and the
/// membership join table the same way, which is why a join table needs no
/// special handling anywhere below — it is a row with an id and a clock like
/// any other.
///
/// Nothing here knows what a task *is*. The engine moves rows of columns, and
/// the meaning of those columns stays where it already lives — in the
/// repositories and the domain.
class SyncedTable {
  const SyncedTable(
    this.info, {
    this.clockColumn = 'updated_at',
    this.deviceLocalColumns = const {},
  });

  /// drift's description of the table: its SQL name, its columns and their
  /// types. Read at runtime so a new column is picked up by regenerating, not
  /// by editing a list here.
  final TableInfo<Table, dynamic> info;

  /// The column both the pull cursor and last-write-wins are measured on.
  ///
  /// `updated_at` on every registered table, completions included. #11 left
  /// this configurable expecting completions to be registered on `created_at`,
  /// since they are immutable events with no `updated_at` of their own
  /// (ADR 0004) — but a cursor on `created_at` never carries a *tombstone*,
  /// because taking a completion back moves `deleted_at` and leaves
  /// `created_at` where it was. #12 settled it the other way: completions gained
  /// an `updated_at` that nothing but the tombstone writes, and the column's
  /// doc comment in `data/database.dart` carries the argument.
  ///
  /// The field stays, because "which column is the clock" is still a property
  /// of a table rather than a constant, and a table that legitimately wants a
  /// different one should be able to say so here rather than in the engine.
  ///
  /// Whatever the column, the comparison degenerates for completions into
  /// exactly the "append and merge, no resolution" ADR 0004 asks for: two
  /// copies of one completion carry identical clocks, so neither supersedes the
  /// other and both devices keep the row they already have.
  final String clockColumn;

  /// Columns of a synced table that are nonetheless this device's own
  /// business, and which sync therefore neither pushes nor applies.
  ///
  /// One column needs this and it is `photos.local_path`: the photo row is
  /// shared, but whether *this* phone has the bytes cached on disk is not. A
  /// replicated `local_path` would have the second device believe it holds a
  /// file it has never downloaded, and the far end would then show a broken
  /// image instead of "waiting for the other device".
  ///
  /// The alternative — a second, device-local table paired one-to-one with
  /// `photos` — buys nothing: the column is genuinely a property of the photo,
  /// it is just a property with a different *scope*. Naming that scope here is
  /// cheaper than a join, and it keeps the remote schema honest, because the
  /// Postgres table simply does not have the column at all.
  ///
  /// Excluded in both directions and in the comparison, so a column left out
  /// of the wire shape cannot read as a change on every pull.
  final Set<String> deviceLocalColumns;

  String get name => info.actualTableName;

  /// The columns sync moves — every column of the table but the device-local
  /// ones.
  Iterable<GeneratedColumn<Object>> get syncedColumns =>
      info.$columns.where((c) => !deviceLocalColumns.contains(c.name));

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
      for (final column in table.syncedColumns)
        column.name: _toRemoteValue(column, local[column.name]),
    };
  }

  /// PostgREST JSON as the raw SQLite values drift stores.
  ///
  /// Columns the remote does not send are left out rather than written as
  /// null, so a backend running an older migration cannot blank a column this
  /// build added. Device-local columns are left out for the stronger reason
  /// that nothing the remote could say about them would be true here.
  Map<String, Object?> toLocal(Map<String, Object?> remote) {
    return {
      for (final column in table.syncedColumns)
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
