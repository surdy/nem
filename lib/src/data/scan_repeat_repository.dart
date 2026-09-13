import '../domain/scan.dart';
import 'database.dart';

/// The `sync_state` keys the repeat window's anchor lives under.
const _targetKey = 'scan_repeat_target';
const _atKey = 'scan_repeat_at';

/// [ScanRepeatStore] over `sync_state` — the repeat window, kept where it
/// survives the process being killed.
///
/// ## Why `sync_state` and not a table of its own
///
/// This is two values, both device-local, both worthless to any other device:
/// which target this phone last accepted a scan of, and when. `sync_state` is
/// PLAN.md's device-local key/value state, is already in the schema — so this
/// needs no migration — and is where the digest's configuration already lives.
/// A table for one row would have bought nothing but a schema version.
///
/// Nothing here is ever synced. Two phones tapping the same tag thirty seconds
/// apart are two people doing the work twice, which is not a fumble and not
/// something to swallow.
class ScanRepeatRepository implements ScanRepeatStore {
  ScanRepeatRepository(this._db);

  final NemDatabase _db;

  /// The stored anchor, or null when there is none — including when what is
  /// stored cannot be read.
  ///
  /// An unreadable value falls back rather than throws, the way the digest's
  /// settings do: this is read on the scan path and on the launch path, and a
  /// window that quietly re-opens is a far better failure than a tap that
  /// crashes instead of completing the work.
  @override
  Future<ScanRepeatAnchor?> read() async {
    final rows = await (_db.select(
      _db.syncState,
    )..where((s) => s.key.isIn([_targetKey, _atKey]))).get();
    final values = {for (final row in rows) row.key: row.value};

    final targetId = values[_targetKey];
    final at = int.tryParse(values[_atKey] ?? '');
    if (targetId == null || targetId.isEmpty || at == null) return null;

    return ScanRepeatAnchor(
      targetId: targetId,
      // Stored as an instant and read back as one. The window measures elapsed
      // time, so the only thing that has to survive is the moment itself —
      // which is why this is epoch milliseconds and not a local wall clock
      // that a timezone change would move underneath it.
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }

  @override
  Future<void> write(ScanRepeatAnchor anchor) async {
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(_db.syncState, [
        SyncStateCompanion.insert(key: _targetKey, value: anchor.targetId),
        SyncStateCompanion.insert(
          key: _atKey,
          value: anchor.at.millisecondsSinceEpoch.toString(),
        ),
      ]);
    });
  }

  @override
  Future<void> clear() async {
    await (_db.delete(
      _db.syncState,
    )..where((s) => s.key.isIn([_targetKey, _atKey]))).go();
  }
}
