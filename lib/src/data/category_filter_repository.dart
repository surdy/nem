import 'database.dart';

/// The `sync_state` key the due list's category filter lives under.
const _filterKey = 'due_list_category_filter';

/// The ids are stored as one comma-separated string, because `sync_state` holds
/// text and a uuid contains no commas. A list short enough to be read in a
/// debugger beats JSON here — nothing else in nem parses this value, and a
/// value that cannot be read falls back to "no filter" rather than throwing.
const _separator = ',';

/// Which categories the due list is filtered to, kept across launches
/// (CONTEXT.md — "Category").
///
/// ## Why `sync_state` and not a synced table
///
/// Because the filter is not data — it is where one device's user has the list
/// pointed *right now*. Two phones can reasonably be looking at two different
/// slices of the same work: the one in the kitchen filtered to kitchen, the one
/// in the car to car. Syncing the filter would mean opening nem on the second
/// phone and finding the first phone's view, with no way to tell that from a
/// bug.
///
/// `sync_state` is PLAN.md's device-local key/value state and is where exactly
/// this kind of thing already lives — the digest's configuration, the scan
/// repeat window's anchor, the device id, the pull cursors. It is already in
/// the schema, so this needs no migration of its own; it is never pushed,
/// because sync moves rows of the domain tables and this is not one of them;
/// and it keeps every piece of persistence in one store with one open path.
///
/// The alternative considered and rejected was `shared_preferences`: a second
/// dependency and a second async initialisation on the launch path, to buy
/// nothing this table does not already give. The other alternative — a column
/// on a synced table, or a row in one — would have made a device-local view
/// into replicated state, which is the wrong answer to the wrong question.
class CategoryFilterRepository {
  CategoryFilterRepository(this._db);

  final NemDatabase _db;

  /// The stored ids, or an empty set for "no filter, show everything".
  ///
  /// Nothing here checks that the ids still name live categories. Pruning
  /// belongs where the live list is known — a category can be deleted on the
  /// other device, so an id stored here can go stale without this device ever
  /// touching the filter — and doing it on read would mean this class querying
  /// a table it otherwise has no business in.
  Future<Set<String>> read() async {
    final row = await (_db.select(
      _db.syncState,
    )..where((s) => s.key.equals(_filterKey))).getSingleOrNull();
    final stored = row?.value ?? '';
    return {
      for (final id in stored.split(_separator))
        if (id.trim().isNotEmpty) id.trim(),
    };
  }

  /// Replaces the filter. An empty set is stored as an empty string rather than
  /// deleting the row, so "the user cleared the filter" and "this device has
  /// never had one" read the same way — which they should.
  Future<void> write(Set<String> categoryIds) async {
    await _db
        .into(_db.syncState)
        .insertOnConflictUpdate(
          SyncStateCompanion.insert(
            key: _filterKey,
            value: categoryIds.join(_separator),
          ),
        );
  }
}
