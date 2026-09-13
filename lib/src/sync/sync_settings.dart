import '../data/database.dart';
import 'sync_cursor.dart';

/// The `sync_state` keys sync owns.
const _urlKey = 'supabase_url';
const _anonKeyKey = 'supabase_anon_key';
const _seededKey = 'outbox_seeded_for';
String _cursorKey(String table) => 'pull_cursor_$table';

/// Where nem syncs to, if anywhere.
///
/// Both fields are user-editable settings rather than build constants, which is
/// the whole of ADR 0002's "backend swap": pointing nem at a self-hosted
/// Supabase is typing a different URL, not shipping a different build. The anon
/// key is not a secret — it is the public key every Supabase client ships with,
/// and what actually protects the data is RLS plus the single account
/// (ADR 0003) — so it lives in the same table as everything else rather than in
/// a keychain.
class SyncSettings {
  const SyncSettings({this.url = '', this.anonKey = ''});

  final String url;
  final String anonKey;

  /// Whether there is anything to connect to.
  ///
  /// Empty is the normal state, not an error: nem is a complete app with no
  /// backend at all (ADR 0001), and everything sync-shaped stays switched off
  /// and out of the way until both fields are filled in.
  bool get isConfigured => normalisedUrl != null && anonKey.trim().isNotEmpty;

  /// The URL with its trailing slash removed, or null if it is not one nem can
  /// use.
  ///
  /// Checked here rather than left to the first failed request, because the
  /// failure mode of a bad URL is otherwise a silent never-syncs: the client
  /// constructs happily and every call times out.
  String? get normalisedUrl {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    // `Uri.parse('https://')` is absolute and has an (empty) authority, so the
    // host has to be checked on its own.
    if (parsed == null || !parsed.isAbsolute || parsed.host.isEmpty) {
      return null;
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
    final text = parsed.toString();
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }

  SyncSettings copyWith({String? url, String? anonKey}) =>
      SyncSettings(url: url ?? this.url, anonKey: anonKey ?? this.anonKey);

  @override
  bool operator ==(Object other) =>
      other is SyncSettings && other.url == url && other.anonKey == anonKey;

  @override
  int get hashCode => Object.hash(url, anonKey);
}

/// Sync's slice of `sync_state`: the backend to talk to, and how far each
/// table's pull has got.
///
/// Device-local, and never itself pushed — sync moves rows of the domain
/// tables, and this is not one of them.
class SyncSettingsRepository {
  SyncSettingsRepository(this._db);

  final NemDatabase _db;

  Future<SyncSettings> read() async {
    final values = await _values([_urlKey, _anonKeyKey]);
    return SyncSettings(
      url: values[_urlKey] ?? '',
      anonKey: values[_anonKeyKey] ?? '',
    );
  }

  Stream<SyncSettings> watch() {
    final query = _db.select(_db.syncState)
      ..where((s) => s.key.isIn([_urlKey, _anonKeyKey]));
    return query.watch().map((rows) {
      final values = {for (final row in rows) row.key: row.value};
      return SyncSettings(
        url: values[_urlKey] ?? '',
        anonKey: values[_anonKeyKey] ?? '',
      );
    });
  }

  Future<void> write(SyncSettings settings) async {
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(_db.syncState, [
        SyncStateCompanion.insert(key: _urlKey, value: settings.url.trim()),
        SyncStateCompanion.insert(
          key: _anonKeyKey,
          value: settings.anonKey.trim(),
        ),
      ]);
    });
  }

  Future<SyncCursor?> cursor(String table) async {
    final values = await _values([_cursorKey(table)]);
    return SyncCursor.tryParse(values[_cursorKey(table)]);
  }

  Future<void> writeCursor(String table, SyncCursor cursor) =>
      _put(_cursorKey(table), cursor.encode());

  /// The backend the outbox has been seeded for, if any.
  ///
  /// Seeding is per backend rather than once ever: pointing nem at a different
  /// Supabase project means that project has none of this device's rows, and
  /// only the rows edited since would ever be pushed otherwise.
  Future<String?> seededFor() async =>
      (await _values([_seededKey]))[_seededKey];

  Future<void> markSeeded(String url) => _put(_seededKey, url);

  /// Forgets every cursor and the seed marker, so the next sync re-pulls from
  /// the beginning and re-pushes everything.
  ///
  /// Run when the URL changes. Nothing is deleted from the domain tables: the
  /// local database is the source of truth (ADR 0001) and changing where it
  /// replicates to is not a reason to lose any of it.
  Future<void> forgetProgress(Iterable<String> tables) async {
    await (_db.delete(
      _db.syncState,
    )..where((s) => s.key.isIn([_seededKey, ...tables.map(_cursorKey)]))).go();
  }

  Future<void> _put(String key, String value) async {
    await _db
        .into(_db.syncState)
        .insertOnConflictUpdate(
          SyncStateCompanion.insert(key: key, value: value),
        );
  }

  Future<Map<String, String>> _values(List<String> keys) async {
    final rows = await (_db.select(
      _db.syncState,
    )..where((s) => s.key.isIn(keys))).get();
    return {for (final row in rows) row.key: row.value};
  }
}
