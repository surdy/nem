import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../domain/binding.dart';
import '../domain/completion.dart';
import '../domain/interval_unit.dart';
import '../domain/task.dart';
import '../photos/photo.dart';

part 'database.g.dart';

/// The `tasks` table from PLAN.md.
///
/// The floating columns (`interval_n`, `interval_unit`) and the fixed column
/// (`rrule`) are mutually exclusive nullable sets, deliberately not unified
/// (ADR 0005).
@DataClassName('TaskRow')
@TableIndex(name: 'idx_tasks_due_date', columns: {#dueDate})
@TableIndex(name: 'idx_tasks_deleted_at', columns: {#deletedAt})
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get notes => text().nullable()();

  /// The target this task is done on (ADR 0008). Optional — plenty of work is
  /// not attached to anything physical.
  ///
  /// No SQLite foreign key. Deletes are soft, so a referenced target row never
  /// actually disappears, and once sync arrives a pull can legitimately deliver
  /// a task before the target it names (PLAN.md — Sync). A constraint would
  /// reject that ordering; the repository keeps the reference honest instead.
  TextColumn get targetId => text().nullable()();

  TextColumn get scheduleMode => textEnum<ScheduleMode>()();

  // Floating only.
  IntColumn get intervalN => integer().nullable()();
  TextColumn get intervalUnit => textEnum<IntervalUnit>().nullable()();

  /// Fixed only: an RFC 5545 `DTSTART` line and an `RRULE` line (ADR 0006).
  ///
  /// The `DTSTART` carries the wall-clock anchor and the IANA zone id that
  /// ADR 0010 requires, which is why this one text column is the whole fixed
  /// representation and there is no separate zone column to migrate to. See
  /// `FixedSchedule.encode`.
  TextColumn get rrule => text().nullable()();

  DateTimeColumn get startDate => dateTime()();

  /// Derived cache, denormalised so the due list is one indexed query
  /// (PLAN.md). Never authoritative — see ADR 0004.
  DateTimeColumn get dueDate => dateTime().nullable()();

  /// Derived cache of the latest live completion (ADR 0004). The authoritative
  /// answer is `MAX(completed_at)` over [Completions]; this column exists so
  /// the value is cheap to sort and show, and is recomputed, never trusted.
  DateTimeColumn get lastCompletedAt => dateTime().nullable()();

  /// The wall-clock "HH:mm" a task reminds at, null when it has not opted in
  /// (CONTEXT.md — "Reminder").
  ///
  /// Declared in the original scaffold and unused until issue #16, so wiring
  /// reminders up needed no migration. Read through `ReminderTime.tryParse`,
  /// which treats an unreadable value as no reminder rather than throwing on
  /// the launch path.
  TextColumn get reminderTime => text().nullable()();

  /// The date a snooze pushed this task out to, or null if it is not snoozed.
  ///
  /// **Not** a derived cache, and the one column on this table that a snooze
  /// could not have lived in otherwise: [dueDate] is rewritten from the
  /// schedule and the completion log by `recomputeDerivedState` on every launch
  /// and after every sync pull (ADR 0004), so a snooze written there would be
  /// erased within a launch. Stored here instead, where nothing derives it, it
  /// is an *input* to that recomputation rather than a casualty of it — see
  /// `domain/snooze.dart`.
  DateTimeColumn get snoozedUntil => dateTime().nullable()();

  /// When [snoozedUntil] was set.
  ///
  /// A completion recorded for later work supersedes the snooze, and this is
  /// what that comparison is against. Nothing is cleared to make it happen, so
  /// tombstoning that completion brings the snooze back (ADR 0004).
  DateTimeColumn get snoozedAt => dateTime().nullable()();

  /// Retired, but kept: an archived task is off the due list and out of the
  /// digest, and its completion log is untouched.
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `completions` table from PLAN.md.
///
/// Append-only (ADR 0004). Rows are inserted and never updated: taking a
/// completion back sets [deletedAt], and correcting one tombstones the row and
/// appends a replacement. Nothing in the repository rewrites `completed_at`,
/// `source` or `note`, which is what lets two devices merge their logs with no
/// conflict resolution at all.
@DataClassName('CompletionRow')
@TableIndex(name: 'idx_completions_task_id', columns: {#taskId})
@TableIndex(name: 'idx_completions_deleted_at', columns: {#deletedAt})
class Completions extends Table {
  TextColumn get id => text()();

  /// The task this completion records work against.
  ///
  /// No SQLite foreign key, and this is the column ADR 0011 argues hardest
  /// about. A pull delivers rows per table in no guaranteed order, so a
  /// completion can legitimately arrive before the task it belongs to — and a
  /// `REFERENCES` constraint, with `PRAGMA foreign_keys = ON`, would refuse the
  /// insert outright. Completions are the one thing nem cannot afford to lose
  /// (ADR 0004: every due date is derived from them and can be reconstructed
  /// from nothing else), so the constraint had to go. A `task_id` that resolves
  /// to nothing is an orphan the application ignores, not corruption.
  TextColumn get taskId => text()();

  /// When the work was done, which is not necessarily when the row was written.
  DateTimeColumn get completedAt => dateTime()();

  /// Constrained to the values of [CompletionSource], stored by name so later
  /// sources are additive.
  TextColumn get source => textEnum<CompletionSource>()();

  TextColumn get note => text().nullable()();

  /// Which device recorded this (PLAN.md — "Sync").
  TextColumn get deviceId => text()();

  DateTimeColumn get createdAt => dateTime()();

  /// The clock sync measures this row on — equal to [createdAt] until the row
  /// is tombstoned, and moved to the moment of the tombstone when it is.
  ///
  /// A completion is an immutable event and this is not a second way to edit
  /// one (ADR 0004): nothing in nem writes it except the tombstone, so for a
  /// completion that stands it is `created_at` and nothing else.
  ///
  /// It exists because `SyncedTable.clockColumn` is both the pull cursor and
  /// the last-write-wins comparison, and a cursor on `created_at` would never
  /// carry a tombstone: taking a completion back on one device moves
  /// `deleted_at` and leaves `created_at` where it was, so the row would sit
  /// behind the other device's cursor forever and the correction would never
  /// arrive. The alternative — a cursor reading the later of `created_at` and
  /// `deleted_at` — needs an expression where PostgREST wants a column: the
  /// pull filters, orders and pages on it, and the conditional `PATCH` compares
  /// against it, so it would mean a generated column in Postgres, which the
  /// codec would then try to write on every insert because it derives the wire
  /// shape from drift's columns. A real column on both sides is the cheaper
  /// half of that choice.
  ///
  /// Append-and-merge is untouched by it (ADR 0004). Two devices' copies of one
  /// completion carry the same `updated_at`, so neither supersedes the other
  /// and both keep what they already have; a tombstone wins by being a
  /// tombstone, not by its clock.
  DateTimeColumn get updatedAt => dateTime()();

  /// Tombstones a correction (PLAN.md). A tombstoned completion no longer
  /// counts towards a task's derived state.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `targets` table from PLAN.md.
///
/// A target is a physical place or object work is done on (CONTEXT.md). Tasks
/// point at it through `tasks.target_id`, and bindings will point at it from the
/// other side in P2 (ADR 0008).
@DataClassName('TargetRow')
@TableIndex(name: 'idx_targets_deleted_at', columns: {#deletedAt})
class Targets extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `bindings` table from PLAN.md.
///
/// One scannable code, one target (CONTEXT.md — "Binding"; ADR 0008). The
/// uniqueness is on `(kind, value)` rather than on `value` alone, because a
/// target can wear a tag and a printed label at once and both carry the same
/// `nem://t/<uuid>` — two rows, two kinds, one value, one target.
@DataClassName('BindingRow')
@TableIndex(name: 'idx_bindings_target_id', columns: {#targetId})
@TableIndex(name: 'idx_bindings_deleted_at', columns: {#deletedAt})
@TableIndex(
  name: 'idx_bindings_kind_value',
  columns: {#kind, #value},
  unique: true,
)
class Bindings extends Table {
  TextColumn get id => text()();

  /// The target this code resolves to.
  ///
  /// No SQLite foreign key, for exactly the reasons `tasks.target_id` has none
  /// (ADR 0011): deletes are soft, so the row it names never actually goes
  /// away, and a sync pull can legitimately deliver a binding before the target
  /// it points at — a constraint would reject that pull and leave the device
  /// unable to converge. A binding whose target does not resolve is handled as
  /// an unknown code, not as corruption.
  TextColumn get targetId => text()();

  /// Constrained to the values of [BindingKind], stored by name.
  TextColumn get kind => textEnum<BindingKind>()();

  /// Our uuid for a tag or a label, the raw product code for a barcode.
  TextColumn get value => text()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  ///
  /// A tombstoned row still occupies its `(kind, value)` slot in the unique
  /// index — deliberately. Re-binding a code that was unbound re-points the row
  /// that is already there rather than inserting a second one, which is also
  /// what keeps the other device's copy of that binding converging on one row.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `categories` table from PLAN.md.
///
/// A category is a user-defined grouping that cuts across targets — kitchen,
/// car, admin (CONTEXT.md — "Category"). It is emphatically not a tag: that
/// word is reserved for NFC hardware, which is why the glossary gives the
/// grouping a word of its own.
///
/// A category groups *tasks*, not targets, and a task can be in several at
/// once — so the membership lives in [TaskCategories] rather than in a column
/// here or on `tasks`.
@DataClassName('CategoryRow')
@TableIndex(name: 'idx_categories_deleted_at', columns: {#deletedAt})
class Categories extends Table {
  TextColumn get id => text()();

  /// What the grouping is called — "kitchen", "the car", "admin".
  TextColumn get name => text()();

  /// The swatch the category is shown in, as a 32-bit ARGB value, or null when
  /// one was never chosen.
  ///
  /// Nullable rather than defaulted, so "no colour yet" is a state the row can
  /// hold honestly: a category pulled from a device running an older build has
  /// no opinion about its colour, and a default written here would look like
  /// one. The UI falls back to a neutral swatch.
  IntColumn get color => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  ///
  /// Deleting a category deletes no work: the tasks that were in it are
  /// untouched, exactly as soft-deleting a target leaves its tasks intact.
  /// What goes with it is the membership rows, tombstoned in the same
  /// transaction — see `CategoryRepository.softDeleteCategory`.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `task_categories` table from PLAN.md — one task's membership of one
/// category.
///
/// ## Why this has an `id` when PLAN.md's block gives it a composite key
///
/// Because it syncs, and everything sync moves is addressed by a single `id`:
/// the outbox names `(table, row_id)`, the drain reads `WHERE id = ?`, the pull
/// cursor is an `(updated_at, id)` pair and last-write-wins compares one row
/// against one row. A composite key would have meant a second addressing scheme
/// through every one of those, which is precisely the "second sync path" that
/// registering a [SyncedTable] exists to avoid. The pair stays unique — a
/// unique index rather than a primary key — so a membership added twice is one
/// row, not two.
///
/// The timestamps are here for the same reason: `created_at` is what the seed
/// walks in order, `updated_at` is the clock sync measures the row on, and
/// `deleted_at` is how a membership is taken back.
@DataClassName('TaskCategoryRow')
@TableIndex(name: 'idx_task_categories_task_id', columns: {#taskId})
@TableIndex(name: 'idx_task_categories_category_id', columns: {#categoryId})
@TableIndex(name: 'idx_task_categories_deleted_at', columns: {#deletedAt})
@TableIndex(
  name: 'idx_task_categories_pair',
  columns: {#taskId, #categoryId},
  unique: true,
)
class TaskCategories extends Table {
  TextColumn get id => text()();

  /// The task that is in the category.
  ///
  /// No SQLite foreign key, and neither does [categoryId] — ADR 0011, and this
  /// table is where its argument bites hardest. A membership row references
  /// *both* sides, sync pulls tables in no guaranteed order, and so a
  /// membership can legitimately arrive before either the task or the category
  /// it names. Two constraints would mean two ways for a perfectly valid pull
  /// to be refused, leaving the device unable to converge. A membership whose
  /// task or category does not resolve is simply not shown, which is what every
  /// read here already does by joining rather than trusting.
  TextColumn get taskId => text()();

  /// The category the task is in.
  TextColumn get categoryId => text()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  ///
  /// Taking a task out of a category tombstones this row rather than deleting
  /// it, and putting it back re-points the row that is already there — the same
  /// bargain [Bindings] strikes with its unique index, and for the same reason:
  /// a hard delete would give the other device a row to resurrect.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The `photos` table from PLAN.md — reference photos on tasks (CONTEXT.md).
///
/// Column for column what PLAN.md's schema block specifies. The argument for
/// the two nullable path columns — which one syncs, which one does not, and why
/// neither is written before it is true — is on [Photo] in `photos/photo.dart`.
@DataClassName('PhotoRow')
@TableIndex(name: 'idx_photos_task_id', columns: {#taskId})
@TableIndex(name: 'idx_photos_deleted_at', columns: {#deletedAt})
class Photos extends Table {
  TextColumn get id => text()();

  /// The task this photo is attached to — never a completion (CONTEXT.md).
  ///
  /// No foreign key, for exactly ADR 0011's reason: a pull delivers rows per
  /// table in no guaranteed order, so a photo can arrive before its task, and
  /// `PRAGMA foreign_keys = ON` would refuse the insert outright.
  TextColumn get taskId => text()();

  /// The object key in the Storage bucket, or null until an upload has
  /// actually succeeded. Non-null is a promise that the bytes are there.
  TextColumn get storagePath => text().nullable()();

  /// The cache file's name on this device, or null when the bytes are not
  /// here. The one column of this table sync never carries — see
  /// `SyncedTable.deviceLocalColumns`.
  TextColumn get localPath => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Soft delete, so a delete beats a stale update when sync arrives (PLAN.md).
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The byte work waiting for a network — uploads, downloads and removals.
///
/// A second queue next to the outbox, deliberately. The outbox is a *dirty set
/// of rows*: an entry names a row and the drain reads that row's current state
/// out of SQLite, which is exactly right for a task and exactly wrong for an
/// image. Bytes are not re-read from the row, they are immutable once written,
/// they are a thousand times larger, they fail differently (a half-uploaded
/// object, a 404 for one that has not arrived yet), and they need an operation
/// on the entry because "push this row" is one verb while "put these bytes",
/// "fetch these bytes" and "delete these bytes" are three.
///
/// Device-local and never itself synced, for the same reason the outbox is not:
/// what this phone still owes the bucket is nobody else's business.
///
/// The primary key is the photo id alone, so a photo has at most one piece of
/// outstanding byte work. Deleting a photo whose upload never went out replaces
/// that upload with a removal rather than queueing both.
@DataClassName('PhotoTransferRow')
@TableIndex(name: 'idx_photo_transfers_enqueued_at', columns: {#enqueuedAt})
class PhotoTransfers extends Table {
  TextColumn get photoId => text()();

  /// Which way the bytes go — see [PhotoTransferOperation].
  TextColumn get operation => textEnum<PhotoTransferOperation>()();

  DateTimeColumn get enqueuedAt => dateTime()();

  /// How many drains have tried and failed on this photo.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// The last failure's message. Surfaced on the task screen, which is what
  /// makes a failed upload something you are told about rather than something
  /// that quietly did not happen.
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {photoId};
}

/// The `sync_state` table from PLAN.md — device-local key/value state.
///
/// Holds the device id every completion records, the digest's configuration,
/// which categories the due list is filtered to, the Supabase base URL and anon
/// key (ADR 0002), and the per-table pull cursors. Never pushed: sync moves
/// rows of the domain tables, and this is not one of them.
class SyncState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Rows this device has changed and not yet pushed (PLAN.md — Sync).
///
/// A *dirty set*, not a log of mutations: an entry names a row, and the push
/// reads that row's current state out of SQLite when it drains. That is what
/// makes it right rather than merely cheap — SQLite is the source of truth
/// (ADR 0001), so the only thing worth sending is what the row says *now*.
/// Editing a task five times offline leaves one entry and pushes once, and a
/// replayed or duplicated drain cannot resurrect an intermediate value that no
/// longer exists anywhere.
///
/// The primary key is `(table_name, row_id)`, which is what collapses those
/// five edits into one entry. [enqueuedAt] is the *first* time the row went
/// dirty and is not bumped by later edits, so the drain order is the order the
/// rows were first touched — a task is pushed before a completion recorded
/// against it.
@DataClassName('OutboxRow')
@TableIndex(name: 'idx_outbox_enqueued_at', columns: {#enqueuedAt})
class Outbox extends Table {
  /// The SQL name of the table the row lives in — one of the six in
  /// `defaultSyncedTables`. Named explicitly because drift's `Table` already
  /// owns the `tableName` getter.
  TextColumn get pendingTable => text().named('table_name')();

  TextColumn get rowId => text()();

  DateTimeColumn get enqueuedAt => dateTime()();

  /// How many drains have tried and failed on this row. Kept for the backoff
  /// and so a row that can never be pushed is visible rather than silent.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// The last failure's message, for the same reason.
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {pendingTable, rowId};
}

@DriftDatabase(
  tables: [
    Tasks,
    Completions,
    Targets,
    Bindings,
    Categories,
    TaskCategories,
    Photos,
    SyncState,
    Outbox,
    PhotoTransfers,
  ],
)
class NemDatabase extends _$NemDatabase {
  NemDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'nem'));

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      // Migrations only ever add. A wipe-and-recreate would destroy the
      // completion log, and the log is the only authoritative record nem has —
      // due dates are derived from it (ADR 0004) and cannot be reconstructed
      // from anything else on the device.
      if (from < 2) {
        await m.createTable(completions);
        await m.createTable(syncState);
        await m.create(idxCompletionsTaskId);
        await m.create(idxCompletionsDeletedAt);
      }
      // v3 adds `targets`. `tasks.target_id` has been declared since v1, so
      // nothing on `tasks` changes — the column simply starts being used.
      if (from < 3) {
        await m.createTable(targets);
        await m.create(idxTargetsDeletedAt);
      }
      // v4 adds `bindings`, so a scanned code can name a target. Nothing else
      // changes: targets and tasks are untouched, and a device that never
      // scans anything simply has an empty table.
      if (from < 4) {
        await m.createTable(bindings);
        await m.create(idxBindingsTargetId);
        await m.create(idxBindingsDeletedAt);
        await m.create(idxBindingsKindValue);
      }
      // v5 adds the two snooze columns. Both are nullable with no default, so
      // every existing task reads as "never snoozed" and nothing on disk is
      // rewritten. `is_archived` has been declared since v1 and needs no
      // migration — archive only starts using it.
      if (from < 5) {
        await m.addColumn(tasks, tasks.snoozedUntil);
        await m.addColumn(tasks, tasks.snoozedAt);
      }
      // v6 adds the outbox (#11). Nothing on any existing table changes, and
      // the table starts empty rather than pre-filled: a device upgrading into
      // this build has no backend configured yet, and what it already holds is
      // seeded into the outbox the first time one is (`SyncEngine.seed`), not
      // here. A device that never configures a backend simply accumulates an
      // entry per row it edits and nothing ever drains them, which costs a row
      // each and changes nothing else (ADR 0001 — the app is whole with no
      // account at all).
      if (from < 6) {
        await m.createTable(outbox);
        await m.create(idxOutboxEnqueuedAt);
      }
      // v7 puts `completions` into sync (#12), which takes two changes to the
      // one table and so is one `TableMigration` rather than two steps.
      //
      // The first is the foreign key on `task_id`, which has to go: a pull can
      // deliver a completion before the task it belongs to, and the constraint
      // would refuse the insert with `PRAGMA foreign_keys = ON` (ADR 0011).
      // SQLite cannot drop a constraint in place, so the table is recreated in
      // the shape the Dart class now describes and every row is copied into it.
      //
      // The second rides along free, because the rows are being rewritten
      // anyway: `updated_at`, which is the column sync's cursor reads. Existing
      // rows take the later of what they have — the tombstone's moment for a
      // completion that was taken back, and `created_at` for one that stands —
      // which is exactly what the column would have held had it always existed.
      if (from < 7) {
        await m.alterTable(
          TableMigration(
            completions,
            newColumns: [completions.updatedAt],
            columnTransformer: {
              completions.updatedAt: coalesce([
                completions.deletedAt,
                completions.createdAt,
              ]),
            },
          ),
        );
      }
      // v8 adds categories and the membership join table (#14). Two new
      // tables and nothing else: `tasks` is untouched, because a task's
      // categories are rows over there rather than a column here — which is
      // what lets a task be in several at once.
      //
      // A device upgrading into this build has no categories, so both tables
      // start empty and every existing task reads as uncategorised. Nothing is
      // queued for push by the upgrade itself, for the reason v6 gives.
      if (from < 8) {
        await m.createTable(categories);
        await m.create(idxCategoriesDeletedAt);
        await m.createTable(taskCategories);
        await m.create(idxTaskCategoriesTaskId);
        await m.create(idxTaskCategoriesCategoryId);
        await m.create(idxTaskCategoriesDeletedAt);
        await m.create(idxTaskCategoriesPair);
      }
      // v9 adds reference photos (#15): the `photos` rows, which sync, and the
      // `photo_transfers` queue, which does not. Nothing on any existing table
      // changes and both start empty — a device upgrading into this build has
      // no photos, and one that never attaches a photo carries two empty
      // tables and nothing else.
      //
      // There is no backfill to do and none that could be done: bytes are not
      // rows, and a migration cannot invent an image. A photo row that arrives
      // from the other device with no bytes here queues its own download on the
      // next sync (`PhotoRepository.reconcile`), which is the same path a
      // freshly installed second phone takes.
      if (from < 9) {
        await m.createTable(photos);
        await m.create(idxPhotosTaskId);
        await m.create(idxPhotosDeletedAt);
        await m.createTable(photoTransfers);
        await m.create(idxPhotoTransfersEnqueuedAt);
      }
    },
    beforeOpen: (details) async {
      // Runs on EVERY open, not only after a migration — keep it to per-open
      // connection setup. Recomputation of derived state belongs to an explicit
      // launch-time call, not here.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
