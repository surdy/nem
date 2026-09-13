import '../data/database.dart';
import '../data/task_repository.dart';
import 'local_rows.dart';
import 'outbox_store.dart';
import 'sync_cursor.dart';
import 'sync_row.dart';
import 'sync_settings.dart';
import 'sync_transport.dart';
import 'synced_table.dart';

/// The tables sync moves.
///
/// All seven of them, and the whole of what #12, #14 and #15 had to add to the
/// engine: the outbox, the drain, the pull, the cursor and the merge are
/// written against [SyncedTable] rather than against any particular table, so
/// registering one is the entire job. #14 added categories and their membership
/// join table by adding two lines here; #15 added a photo's *row* by adding
/// one.
///
/// The order is roughly parents before children — a target before the tasks and
/// bindings that name it, a category before the memberships that name it, a
/// task before its completions — which is a convenience and never a
/// requirement. A pull can legitimately deliver a row before the row it points
/// at (ADR 0011), no table here carries a foreign key that could refuse it, and
/// nothing in this file treats it as an error; the ordering only means the
/// common case resolves in one sync rather than two. `task_categories` is last
/// of the mutable tables for that reason: it points at two rows rather than
/// one, so it is the table with the most to gain from arriving late.
///
/// Every one of them uses the default clock column, `updated_at`, completions
/// included — see the column's doc comment in `data/database.dart` for why
/// completions have one at all.
List<SyncedTable> defaultSyncedTables(NemDatabase db) => [
  SyncedTable(db.targets),
  SyncedTable(db.categories),
  SyncedTable(db.tasks),
  SyncedTable(db.bindings),
  SyncedTable(db.taskCategories),
  SyncedTable(db.completions),
  // A photo's *row* syncs here like any other; its bytes do not, and go
  // through `photos/photo_sync.dart` instead. `local_path` says whether this
  // device holds those bytes, which is true of a device rather than of the
  // photo, so it is excluded from the wire shape — see
  // `SyncedTable.deviceLocalColumns`.
  SyncedTable(db.photos, deviceLocalColumns: const {'local_path'}),
];

/// How many rows one pull request asks for.
///
/// Small enough that a phone on a train makes progress between dropouts — the
/// cursor is written after every page, so an interrupted pull resumes at the
/// page boundary rather than starting again.
const _defaultPageSize = 200;

/// What one sync did.
class SyncReport {
  const SyncReport({
    this.pushed = 0,
    this.superseded = 0,
    this.pulled = 0,
    this.rejected = 0,
    this.pending = 0,
    this.failure,
  });

  /// Rows written to the backend.
  final int pushed;

  /// Rows dropped from the outbox unsent, because the backend's copy stands.
  final int superseded;

  /// Rows written into SQLite from the backend.
  final int pulled;

  /// Rows the backend sent that the local copy beat.
  final int rejected;

  /// Outbox entries still waiting when this sync stopped.
  final int pending;

  /// Why it stopped early, if it did.
  final SyncTransportFailure? failure;

  bool get isComplete => failure == null;

  SyncReport _merge(SyncReport other) => SyncReport(
    pushed: pushed + other.pushed,
    superseded: superseded + other.superseded,
    pulled: pulled + other.pulled,
    rejected: rejected + other.rejected,
    pending: other.pending,
    failure: failure ?? other.failure,
  );

  @override
  String toString() =>
      'SyncReport(pushed: $pushed, superseded: $superseded, '
      'pulled: $pulled, rejected: $rejected, pending: $pending'
      '${failure == null ? '' : ', failed: ${failure!.message}'})';
}

/// Push, pull, and the decisions in between.
///
/// Everything here is a decision about rows and is exercised against
/// `FakeSyncTransport`; the only thing that ever touches a network is behind
/// [SyncTransport], which is a testing seam and not a backend abstraction (see
/// `sync_transport.dart`, and ADR 0002).
///
/// Ordering is push-then-pull. The device is the source of truth (ADR 0001), so
/// what it already knows goes up before anything comes down: pulling first
/// would mean judging a remote row against a local one that has not yet been
/// offered, and an outbox entry that then loses would have lost to a row that
/// the other device wrote without ever having seen ours.
class SyncEngine {
  SyncEngine({
    required NemDatabase db,
    required this.transport,
    required this.settings,
    required this.tasks,
    List<SyncedTable>? tables,
    this.pageSize = _defaultPageSize,
  }) : _rows = LocalRows(db),
       outbox = OutboxStore(db),
       tables = tables ?? defaultSyncedTables(db);

  final SyncTransport transport;
  final SyncSettingsRepository settings;

  /// Only so a pull can recompute the derived caches afterwards, which ADR 0004
  /// requires after every pull — a completion or a schedule arriving from the
  /// other device invalidates a due date that nothing else would rewrite.
  final TaskRepository tasks;

  final List<SyncedTable> tables;
  final OutboxStore outbox;
  final LocalRows _rows;

  /// How many rows one pull request asks for; small in tests, so paging and
  /// the cursor's behaviour at a page boundary are exercised on a handful of
  /// rows rather than on two hundred.
  final int pageSize;

  /// Push everything queued, then pull everything new.
  Future<SyncReport> sync() async {
    final drained = await drainOutbox();
    // A failed drain is a failed network. Trying the pull anyway would be a
    // second timeout for the same reason, on the foreground path.
    if (!drained.isComplete) return drained;
    return drained._merge(await pull());
  }

  /// Queues every row this device already has, once per backend.
  ///
  /// Without this, signing in on a phone that has been tracking work for a
  /// month pushes nothing: the outbox only knows about rows changed since it
  /// existed, so a year of tasks nobody happens to edit again would never reach
  /// the second device. Marked against the URL, so pointing nem at a different
  /// project seeds again — that project has none of these rows either.
  Future<void> seed({DateTime? now}) async {
    final current = await settings.read();
    final url = current.normalisedUrl;
    if (url == null) return;
    if (await settings.seededFor() == url) return;

    // A different project — or the first one — holds none of this device's
    // rows, and any cursor kept from the previous backend points into a
    // timeline that has nothing to do with this one.
    await settings.forgetProgress([for (final table in tables) table.name]);

    final timestamp = now ?? DateTime.now();
    for (final table in tables) {
      for (final id in await _rows.ids(table)) {
        // `insertOrIgnore`, so a row already queued keeps the moment it went
        // dirty rather than being pushed back behind the seed.
        await outbox.enqueue(table.name, id, now: timestamp);
      }
    }
    await settings.markSeeded(url);
  }

  /// Pushes queued rows, oldest first, and stops at the first network failure.
  ///
  /// A partial drain is a normal outcome, not a broken one: entries pushed
  /// before the failure are gone, the one that failed keeps its place with its
  /// attempt count raised, and everything behind it is untouched and still in
  /// order. The next drain picks up exactly there.
  Future<SyncReport> drainOutbox() async {
    var pushed = 0;
    var superseded = 0;

    for (final entry in await outbox.pending()) {
      final table = _tableNamed(entry.table);
      if (table == null) {
        // A table this build no longer syncs. Drop it rather than block the
        // queue behind something nothing can push.
        await outbox.remove(entry.table, entry.rowId);
        continue;
      }

      final raw = await _rows.read(table, entry.rowId);
      if (raw == null) {
        // Nothing to push. Deletes are soft, so this is a row that was never
        // written rather than one that has gone.
        await outbox.remove(entry.table, entry.rowId);
        continue;
      }

      final codec = SyncCodec(table, _rows.types);
      final row = _rowFrom(table, codec, codec.toRemote(raw));
      try {
        if (await _push(table, row)) {
          pushed++;
        } else {
          superseded++;
        }
        await outbox.remove(entry.table, entry.rowId);
      } on SyncTransportFailure catch (failure) {
        await outbox.recordFailure(entry.table, entry.rowId, failure.message);
        return SyncReport(
          pushed: pushed,
          superseded: superseded,
          pending: await outbox.count(),
          failure: failure,
        );
      }
    }

    return SyncReport(
      pushed: pushed,
      superseded: superseded,
      pending: await outbox.count(),
    );
  }

  /// Whether the backend took [row].
  ///
  /// Conditional update first, insert second. The update carries the whole of
  /// the conflict rule in its filters, so the common case — a row that exists
  /// on both sides and has been edited here — is one request that either writes
  /// or does not, with no read-then-write window for the other device to slip
  /// into. Zero rows written means either "no such row" or "the remote copy
  /// stands", and the insert is what tells them apart: it succeeds in the first
  /// case and raises [RemoteRowExists] in the second.
  ///
  /// A row that arrives between the two requests also lands on
  /// [RemoteRowExists], and is treated the same way — leave it, and let the
  /// next pull bring it down. Retrying the update here would buy one round of a
  /// race that two phones cannot meaningfully lose.
  Future<bool> _push(SyncedTable table, SyncRow row) async {
    final written = await transport.updateIfSuperseded(
      table: table.name,
      clockColumn: table.clockColumn,
      row: row,
    );
    if (written > 0) return true;

    try {
      await transport.insertRow(table: table.name, row: row.values);
      return true;
    } on RemoteRowExists {
      return false;
    }
  }

  /// Pulls every table's changes since its cursor.
  Future<SyncReport> pull() async {
    var report = const SyncReport();
    for (final table in tables) {
      report = report._merge(await _pullTable(table));
      if (!report.isComplete) break;
    }
    if (report.pulled > 0) {
      // ADR 0004: the due date and last-completed caches are derived, and a
      // pulled row can invalidate them. Recomputed here rather than left to the
      // next launch, because the due list is on screen now.
      await tasks.recomputeDerivedState();
    }
    return SyncReport(
      pushed: report.pushed,
      superseded: report.superseded,
      pulled: report.pulled,
      rejected: report.rejected,
      pending: await outbox.count(),
      failure: report.failure,
    );
  }

  /// Pulls one table, page by page, and remembers how far it *learned*.
  ///
  /// ## Why the stored cursor only moves over rows that were applied
  ///
  /// The clock a row is filtered and ordered on is the writing device's, not
  /// the server's: nothing in `supabase/` computes anything and no trigger
  /// restamps `updated_at` (ADR 0001), because the value last-write-wins
  /// compares has to be the moment the *edit* happened. The price is that rows
  /// do not reach the backend in clock order. A phone that spent a fortnight
  /// offline pushes a fortnight of completions the moment it reconnects, all of
  /// them stamped when the work was done, and they land *behind* everything the
  /// other phone wrote in the meantime.
  ///
  /// So "the last row I read" is the wrong thing to remember. A device that
  /// pushed its own rows and pulled them straight back would advance its cursor
  /// over its own timeline and step clean over the other device's fortnight —
  /// which is losing completions, the one thing nem cannot afford to lose
  /// (ADR 0004), silently and permanently.
  ///
  /// "The last row I *applied*" is the right thing, and it is what this stores.
  /// A device only moves its cursor when it learns something from the backend,
  /// so a device that has learnt nothing since Tuesday still asks for
  /// everything after Tuesday — which is exactly the window the other device
  /// has been filling up. The cost is re-reading the rows in between on each
  /// pull, which is one comparison per row that writes nothing.
  ///
  /// It is not a total order, and two devices are what it is sound for. A third
  /// writer pushing a row older than one this device has already applied from a
  /// *different* writer would still be stepped over. With the two devices
  /// ADR 0003 describes, and an outbox that drains oldest-dirty first, the rows
  /// a peer pushes arrive in its own clock order and this holds.
  Future<SyncReport> _pullTable(SyncedTable table) async {
    final codec = SyncCodec(table, _rows.types);
    final stored = await settings.cursor(table.name);
    // Where reading has got to, which advances over every row so that paging
    // terminates, and what has been learnt, which is what is written down.
    var reached = stored;
    var pulled = 0;
    var rejected = 0;

    while (true) {
      final List<Map<String, Object?>> page;
      try {
        page = await transport.fetchChanges(
          table: table.name,
          clockColumn: table.clockColumn,
          after: reached,
          limit: pageSize,
        );
      } on SyncTransportFailure catch (failure) {
        return SyncReport(pulled: pulled, rejected: rejected, failure: failure);
      }
      if (page.isEmpty) break;

      final before = reached;
      SyncCursor? learned;
      for (final json in page) {
        final remote = _rowFrom(table, codec, json);
        if (await _apply(table, codec, remote)) {
          pulled++;
          learned = SyncCursor.after(remote);
        } else {
          rejected++;
        }
        reached = SyncCursor.after(remote);
      }
      // Written per page rather than per pull, so an interrupted pull resumes
      // at the last row it applied rather than starting again.
      if (learned != null) await settings.writeCursor(table.name, learned);

      // The cursor must have moved past every row of the page, or the next
      // request asks the same question and gets the same answer forever. It
      // cannot fail to when the backend honours the `(clock, id)` filter and
      // ordering; stopping here rather than looping is what turns a backend
      // that does not — an older schema with no index, a proxy reordering
      // rows — into a sync that does nothing instead of one that never
      // returns.
      if (before != null &&
          !before.isBefore(_rowFrom(table, codec, page.last))) {
        break;
      }
      if (page.length < pageSize) break;
    }

    return SyncReport(pulled: pulled, rejected: rejected);
  }

  /// Writes [remote] into SQLite if it supersedes what is there. Returns
  /// whether it did.
  Future<bool> _apply(
    SyncedTable table,
    SyncCodec codec,
    SyncRow remote,
  ) async {
    final raw = await _rows.read(table, remote.id);
    final local = raw == null
        ? null
        : _rowFrom(table, codec, codec.toRemote(raw));

    if (!remoteSupersedes(local: local, remote: remote)) return false;

    // A row this device pushed a moment ago comes back down on the next pull,
    // wins the tie by the rule in `sync_row.dart`, and is byte-for-byte what is
    // already on disk. Writing it would invalidate every drift stream watching
    // the table and redraw the due list for nothing, so identical is treated as
    // nothing to do — the tie-break still decides *which* version stands, it
    // just does not write when the two agree.
    if (local != null && _sameValues(local.values, remote.values)) return false;

    final values = codec.toLocal(remote.values);
    if (raw == null) {
      await _rows.insert(table, values);
    } else {
      await _rows.update(table, remote.id, values);
    }
    return true;
  }

  /// Whether the remote row says nothing the local one does not.
  ///
  /// Compared over the columns the backend actually sent, so a backend running
  /// an older migration — one column short — does not read as a change on every
  /// single pull.
  static bool _sameValues(
    Map<String, Object?> local,
    Map<String, Object?> remote,
  ) {
    for (final entry in remote.entries) {
      if (local[entry.key] != entry.value) return false;
    }
    return true;
  }

  SyncRow _rowFrom(
    SyncedTable table,
    SyncCodec codec,
    Map<String, Object?> json,
  ) {
    final clock = codec.readTime(json, table.clockColumn);
    if (clock == null) {
      throw FormatException(
        '${table.name} row has no ${table.clockColumn}',
        json,
      );
    }
    return SyncRow(
      id: json['id']! as String,
      clock: clock,
      deletedAt: table.hasSoftDelete
          ? codec.readTime(json, 'deleted_at')
          : null,
      values: json,
    );
  }

  SyncedTable? _tableNamed(String name) {
    for (final table in tables) {
      if (table.name == name) return table;
    }
    return null;
  }
}
