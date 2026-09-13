import '../domain/digest.dart';
import 'database.dart';

/// The `sync_state` keys the digest's configuration lives under.
const _enabledKey = 'digest_enabled';
const _timeKey = 'digest_time';

/// Reads and writes the digest's configuration (CONTEXT.md — "Digest").
///
/// ## Why `sync_state` and not `shared_preferences`
///
/// The digest time is a property of a device, not of the work: two phones can
/// reasonably want the same tasks announced at different hours, and a notified
/// device is the one holding the pending notifications. `sync_state` is
/// already described in PLAN.md as device-local key/value state, is already in
/// the schema — so this needs no migration, which matters while the schema is
/// being changed elsewhere — and it keeps every piece of persistence in one
/// store with one open path.
///
/// `shared_preferences` would have meant a second dependency, a second async
/// initialisation on the launch path, and a second place to look for state,
/// to buy nothing that the existing table does not already give.
///
/// Nothing here is ever pushed: the sync design (PLAN.md) moves rows of the
/// domain tables, and `sync_state` is explicitly not one of them.
class DigestSettingsRepository {
  DigestSettingsRepository(this._db);

  final NemDatabase _db;

  /// The stored settings, falling back to [DigestSettings.defaults].
  ///
  /// Unreadable values fall back rather than throw. This is read on the launch
  /// path, and a digest that quietly reverts to its default is a far better
  /// failure than an app that will not start.
  Future<DigestSettings> read() async {
    final rows = await (_db.select(
      _db.syncState,
    )..where((s) => s.key.isIn([_enabledKey, _timeKey]))).get();
    final values = {for (final row in rows) row.key: row.value};

    return DigestSettings(
      isEnabled: values[_enabledKey] == 'true',
      time:
          DigestTime.tryParse(values[_timeKey] ?? '') ??
          DigestSettings.defaults.time,
    );
  }

  Future<void> write(DigestSettings settings) async {
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(_db.syncState, [
        SyncStateCompanion.insert(
          key: _enabledKey,
          value: settings.isEnabled.toString(),
        ),
        SyncStateCompanion.insert(key: _timeKey, value: settings.time.asHhMm),
      ]);
    });
  }
}
