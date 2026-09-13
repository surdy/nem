import 'package:nem/src/data/database.dart';
import 'package:nem/src/sync/local_rows.dart';
import 'package:nem/src/sync/synced_table.dart';

/// A `tasks` row in the shape PostgREST sends, as if the other device had
/// pushed it.
///
/// Written out in full rather than derived from a local row, so the tests that
/// use it are checking that nem reads what the *backend* would send — every
/// column present, timestamps as ISO-8601 strings, `is_archived` a real
/// boolean — rather than that it reads back what it just wrote.
Map<String, Object?> remoteTaskJson({
  required String id,
  String title = 'Replace the water filter',
  String? notes,
  String? targetId,
  required DateTime updatedAt,
  DateTime? createdAt,
  DateTime? startDate,
  DateTime? dueDate,
  DateTime? deletedAt,
  bool isArchived = false,
  int intervalN = 30,
  String intervalUnit = 'day',
}) {
  String? iso(DateTime? value) => value?.toUtc().toIso8601String();
  final created = createdAt ?? updatedAt;
  return {
    'id': id,
    'title': title,
    'notes': notes,
    'target_id': targetId,
    'schedule_mode': 'floating',
    'interval_n': intervalN,
    'interval_unit': intervalUnit,
    'rrule': null,
    'start_date': iso(startDate ?? created),
    'due_date': iso(dueDate),
    'last_completed_at': null,
    'reminder_time': null,
    'snoozed_until': null,
    'snoozed_at': null,
    'is_archived': isArchived,
    'created_at': iso(created),
    'updated_at': iso(updatedAt),
    'deleted_at': iso(deletedAt),
  };
}

/// A `completions` row in the shape PostgREST sends, as if the work had been
/// recorded on the other phone.
///
/// `updated_at` defaults to `created_at`, which is what a completion that stands
/// carries — the column only moves when the row is tombstoned (ADR 0004, and
/// the column's doc comment in `data/database.dart`).
Map<String, Object?> remoteCompletionJson({
  required String id,
  required String taskId,
  required DateTime completedAt,
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? deletedAt,
  String source = 'manual',
  String? note,
  String deviceId = 'the-other-phone',
}) {
  String? iso(DateTime? value) => value?.toUtc().toIso8601String();
  final created = createdAt ?? completedAt;
  return {
    'id': id,
    'task_id': taskId,
    'completed_at': iso(completedAt),
    'source': source,
    'note': note,
    'device_id': deviceId,
    'created_at': iso(created),
    'updated_at': iso(updatedAt ?? deletedAt ?? created),
    'deleted_at': iso(deletedAt),
  };
}

/// A local row, read out and converted the way a push would.
Future<Map<String, Object?>> localTaskAsRemote(
  NemDatabase db,
  String id,
) async {
  final table = SyncedTable(db.tasks);
  final rows = LocalRows(db);
  final raw = await rows.read(table, id);
  if (raw == null) throw StateError('no local task $id');
  return SyncCodec(table, rows.types).toRemote(raw);
}
