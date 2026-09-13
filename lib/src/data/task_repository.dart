import 'package:drift/drift.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/completion.dart';
import '../domain/fixed_schedule.dart';
import '../domain/interval_unit.dart';
import '../domain/schedule.dart';
import '../domain/task.dart';
import 'database.dart';
import 'ids.dart';

/// The `sync_state` key this device's identifier is stored under.
const _deviceIdKey = 'device_id';

/// Reads and writes tasks and their completions, and keeps the derived caches
/// on `tasks` in step with the completion log.
///
/// The division of labour is ADR 0004's: the `completions` rows are the truth,
/// and `tasks.last_completed_at` / `tasks.due_date` are caches that exist only
/// so the due list can sort and page in SQL (PLAN.md). Every task this
/// repository hands out has its last completion read back out of the log by the
/// same query that reads the task, so a stale cache can misorder the list but
/// can never display a wrong due date.
class TaskRepository {
  TaskRepository(this._db);

  final NemDatabase _db;

  String? _cachedDeviceId;

  /// Live tasks, soonest due first.
  Stream<List<Task>> watchDueList() {
    final lastCompletedAt = _lastCompletedAtExpression();
    final query = _db.select(_db.tasks).join([])
      ..addColumns([lastCompletedAt])
      ..where(_db.tasks.deletedAt.isNull() & _db.tasks.isArchived.equals(false))
      ..orderBy([
        OrderingTerm(expression: _db.tasks.dueDate),
        OrderingTerm(expression: _db.tasks.title),
      ]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          _toDomain(row.readTable(_db.tasks), row.read(lastCompletedAt)),
      ],
    );
  }

  Future<List<Task>> allTasks() async {
    final lastCompletedAt = _lastCompletedAtExpression();
    final rows =
        await (_db.select(_db.tasks).join([])
              ..addColumns([lastCompletedAt])
              ..where(_db.tasks.deletedAt.isNull()))
            .get();
    return [
      for (final row in rows)
        _toDomain(row.readTable(_db.tasks), row.read(lastCompletedAt)),
    ];
  }

  /// Live tasks at one target, soonest due first.
  ///
  /// Archived tasks are included: a target's detail screen is the answer to
  /// "what is tracked here", not "what is due here".
  Stream<List<Task>> watchTasksForTarget(String targetId) {
    final lastCompletedAt = _lastCompletedAtExpression();
    final query = _db.select(_db.tasks).join([])
      ..addColumns([lastCompletedAt])
      ..where(
        _db.tasks.deletedAt.isNull() & _db.tasks.targetId.equals(targetId),
      )
      ..orderBy([
        OrderingTerm(expression: _db.tasks.dueDate),
        OrderingTerm(expression: _db.tasks.title),
      ]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          _toDomain(row.readTable(_db.tasks), row.read(lastCompletedAt)),
      ],
    );
  }

  /// Creates a task with a floating schedule.
  Future<Task> createFloatingTask({
    required String title,
    String? notes,
    String? targetId,
    required int intervalN,
    required IntervalUnit intervalUnit,
    required DateTime startDate,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final schedule = FloatingSchedule(
      intervalN: intervalN,
      intervalUnit: intervalUnit,
      startDate: startDate,
    );
    final task = Task(
      id: newId(),
      title: title,
      notes: (notes == null || notes.trim().isEmpty) ? null : notes.trim(),
      targetId: targetId,
      scheduleMode: ScheduleMode.floating,
      floatingSchedule: schedule,
      startDate: startDate,
      createdAt: timestamp,
      updatedAt: timestamp,
    );

    await _db
        .into(_db.tasks)
        .insert(
          TasksCompanion.insert(
            id: task.id,
            title: task.title,
            notes: Value(task.notes),
            targetId: Value(task.targetId),
            scheduleMode: ScheduleMode.floating,
            intervalN: Value(intervalN),
            intervalUnit: Value(intervalUnit),
            startDate: startDate,
            // Written on every mutation that could invalidate it (PLAN.md).
            dueDate: Value(task.dueDate),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    return task;
  }

  /// Creates a task with a fixed schedule (ADR 0005).
  ///
  /// The schedule arrives already built rather than as loose frequency and
  /// weekday arguments, because [FixedSchedule.encode] is what defines the
  /// stored form and only the schedule knows it. `start_date` is written too,
  /// mirroring the anchor: the column is not null, and it is the stand-in if a
  /// later hand-edit ever leaves the rule without its `DTSTART` line.
  Future<Task> createFixedTask({
    required String title,
    String? notes,
    String? targetId,
    required FixedSchedule schedule,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final task = Task(
      id: newId(),
      title: title,
      notes: (notes == null || notes.trim().isEmpty) ? null : notes.trim(),
      targetId: targetId,
      scheduleMode: ScheduleMode.fixed,
      rrule: schedule.encode(),
      fixedSchedule: schedule,
      startDate: schedule.anchor,
      createdAt: timestamp,
      updatedAt: timestamp,
    );

    await _db
        .into(_db.tasks)
        .insert(
          TasksCompanion.insert(
            id: task.id,
            title: task.title,
            notes: Value(task.notes),
            targetId: Value(task.targetId),
            scheduleMode: ScheduleMode.fixed,
            rrule: Value(task.rrule),
            startDate: task.startDate,
            // Written on every mutation that could invalidate it (PLAN.md).
            dueDate: Value(task.dueDate),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
    return task;
  }

  /// Records that a task was performed (CONTEXT.md — "Completion").
  ///
  /// This only ever inserts (ADR 0004). [completedAt] defaults to now, and is
  /// separate from the row's `created_at` so a completion can be recorded after
  /// the fact. The task's derived cache is refreshed from the log afterwards —
  /// the returned completion is what [undoCompletion] needs to take it back.
  ///
  /// The task's own `updated_at` is deliberately left alone: a completion is
  /// not an edit of the task, and the caches it moves do not sync as truth.
  Future<Completion> recordCompletion(
    String taskId, {
    DateTime? completedAt,
    CompletionSource source = CompletionSource.manual,
    String? note,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final trimmed = note?.trim();
    final completion = Completion(
      id: newId(),
      taskId: taskId,
      completedAt: completedAt ?? timestamp,
      source: source,
      note: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      deviceId: await deviceId(),
      createdAt: timestamp,
    );

    await _db
        .into(_db.completions)
        .insert(
          CompletionsCompanion.insert(
            id: completion.id,
            taskId: completion.taskId,
            completedAt: completion.completedAt,
            source: completion.source,
            note: Value(completion.note),
            deviceId: completion.deviceId,
            createdAt: completion.createdAt,
          ),
        );

    await _refreshDerivedState(taskId);
    return completion;
  }

  /// Takes a completion back by tombstoning it — the undo behind the due list's
  /// five-second affordance.
  ///
  /// The row stays and only `deleted_at` is set, so the tombstone merges with
  /// the other device's copy of the same completion rather than being
  /// resurrected by it (ADR 0004). The task's derived state falls back to
  /// whatever completions are left, which is how undo restores the previous due
  /// date without that due date ever having been stored.
  Future<void> undoCompletion(Completion completion, {DateTime? now}) async {
    await _tombstone(completion.id, now ?? DateTime.now());
    await _refreshDerivedState(completion.taskId);
  }

  /// Corrects a completion — "I did that on Tuesday, not today".
  ///
  /// There is no update path, so a correction is a tombstone plus a fresh row
  /// (ADR 0004). Returns the replacement.
  Future<Completion> correctCompletion(
    Completion completion, {
    required DateTime completedAt,
    String? note,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    await _tombstone(completion.id, timestamp);
    return recordCompletion(
      completion.taskId,
      completedAt: completedAt,
      source: completion.source,
      note: note ?? completion.note,
      now: timestamp,
    );
  }

  /// A task's surviving completions, most recent work first.
  ///
  /// Tombstoned rows are left out: they are still on disk, but they no longer
  /// say that the work happened.
  Future<List<Completion>> completionsFor(String taskId) async {
    final rows =
        await (_db.select(_db.completions)
              ..where((c) => c.taskId.equals(taskId) & c.deletedAt.isNull())
              ..orderBy([
                (c) => OrderingTerm(
                  expression: c.completedAt,
                  mode: OrderingMode.desc,
                ),
              ]))
            .get();
    return rows.map(_toCompletion).toList();
  }

  /// Recomputes the derived caches on every task from the completion log.
  ///
  /// PLAN.md requires this on app launch, after every sync pull, and on every
  /// write that could invalidate the caches. It is called explicitly rather
  /// than from drift's `beforeOpen`, which fires on every database open and
  /// sits on the cold-start path.
  ///
  /// Returns how many tasks needed correcting, which is zero on a second run —
  /// the recomputation is a pure function of rows that it does not itself
  /// change.
  Future<int> recomputeDerivedState() => _recompute();

  /// The identifier of this device, recorded on every completion.
  ///
  /// Minted on first use and kept in `sync_state`, which PLAN.md already
  /// earmarks for it. Two devices can then tell their completions apart once
  /// sync arrives in P3.
  Future<String> deviceId() async {
    final cached = _cachedDeviceId;
    if (cached != null) return cached;

    await _db
        .into(_db.syncState)
        .insert(
          SyncStateCompanion.insert(key: _deviceIdKey, value: newId()),
          // Whoever inserted first wins; a concurrent caller reads that value
          // back rather than overwriting it.
          mode: InsertMode.insertOrIgnore,
        );
    final row = await (_db.select(
      _db.syncState,
    )..where((s) => s.key.equals(_deviceIdKey))).getSingle();
    return _cachedDeviceId = row.value;
  }

  /// Refreshes the derived caches for one task, after a write to its log.
  Future<void> _refreshDerivedState(String taskId) => _recompute(taskId);

  Future<int> _recompute([String? taskId]) async {
    final select = _db.select(_db.tasks)..where((t) => t.deletedAt.isNull());
    if (taskId != null) select.where((t) => t.id.equals(taskId));
    final rows = await select.get();
    final lastCompletions = await _lastCompletionByTask(taskId);

    var updated = 0;
    await _db.batch((batch) {
      for (final row in rows) {
        final lastCompletedAt = lastCompletions[row.id];
        final dueDate = _toDomain(row, lastCompletedAt).dueDate;
        if (_sameInstant(lastCompletedAt, row.lastCompletedAt) &&
            _sameInstant(dueDate, row.dueDate)) {
          continue;
        }
        updated++;
        batch.update(
          _db.tasks,
          TasksCompanion(
            lastCompletedAt: Value(lastCompletedAt),
            dueDate: Value(dueDate),
          ),
          where: (t) => t.id.equals(row.id),
        );
      }
    });
    return updated;
  }

  /// Whether two nullable date-times name the same moment.
  ///
  /// `==` is not good enough here. A fixed schedule's due date is a
  /// `TZDateTime`, whose `==` demands that the other side also be a
  /// `TZDateTime` in the same location — and what comes back out of the column
  /// is a plain `DateTime`. Comparing with `==` would report every fixed task
  /// as changed on every recomputation, so nothing would ever converge.
  static bool _sameInstant(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.isAtSameMomentAs(b);
  }

  /// The latest live completion per task, as one grouped query.
  ///
  /// `MAX` is what makes the order completions arrive in irrelevant: a
  /// completion pulled from the other device after a later one was recorded
  /// locally lands in the log and simply does not win.
  Future<Map<String, DateTime>> _lastCompletionByTask(String? taskId) async {
    final latest = _db.completions.completedAt.max();
    final query = _db.selectOnly(_db.completions)
      ..addColumns([_db.completions.taskId, latest])
      ..where(
        taskId == null
            ? _db.completions.deletedAt.isNull()
            : _db.completions.deletedAt.isNull() &
                  _db.completions.taskId.equals(taskId),
      )
      ..groupBy([_db.completions.taskId]);

    return {
      for (final row in await query.get())
        row.read(_db.completions.taskId)!: ?row.read(latest),
    };
  }

  /// `MAX(completed_at)` over a task's live completions, correlated on
  /// `tasks.id`.
  ///
  /// Read alongside every task row so the domain object's last completion comes
  /// from the log rather than from the cached column (ADR 0004).
  Expression<DateTime> _lastCompletedAtExpression() {
    return subqueryExpression<DateTime>(
      _db.selectOnly(_db.completions)
        ..addColumns([_db.completions.completedAt.max()])
        ..where(
          _db.completions.taskId.equalsExp(_db.tasks.id) &
              _db.completions.deletedAt.isNull(),
        ),
    );
  }

  Future<void> _tombstone(String completionId, DateTime now) async {
    await (_db.update(_db.completions)
          ..where((c) => c.id.equals(completionId) & c.deletedAt.isNull()))
        .write(CompletionsCompanion(deletedAt: Value(now)));
  }

  /// [lastCompletedAt] is passed in rather than read from [row] because the
  /// column is a cache; the value here comes from the completion log.
  Task _toDomain(TaskRow row, DateTime? lastCompletedAt) {
    final intervalN = row.intervalN;
    final intervalUnit = row.intervalUnit;
    return Task(
      id: row.id,
      title: row.title,
      notes: row.notes,
      targetId: row.targetId,
      scheduleMode: row.scheduleMode,
      floatingSchedule:
          (row.scheduleMode == ScheduleMode.floating &&
              intervalN != null &&
              intervalUnit != null)
          ? FloatingSchedule(
              intervalN: intervalN,
              intervalUnit: intervalUnit,
              startDate: row.startDate,
            )
          : null,
      rrule: row.rrule,
      fixedSchedule: row.scheduleMode == ScheduleMode.fixed
          ? _parseFixedSchedule(row)
          : null,
      startDate: row.startDate,
      lastCompletedAt: lastCompletedAt,
      reminderTime: row.reminderTime,
      isArchived: row.isArchived,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  /// Parses a stored fixed schedule, or gives up quietly.
  ///
  /// A rule this build cannot read is not an error the due list should die of:
  /// storage is strictly more expressive than the editor (ADR 0006), so an
  /// imported or hand-edited rule can legitimately be unreadable here. The task
  /// keeps its raw `rrule` text and simply has no due date until something can
  /// read it. Showing such a rule as read-only text is issue #4.
  FixedSchedule? _parseFixedSchedule(TaskRow row) {
    final stored = row.rrule;
    if (stored == null) return null;
    try {
      final schedule = FixedSchedule.parse(
        stored,
        defaultAnchor: row.startDate,
        defaultZoneId: tz.local.name,
      );
      // Resolve the zone now. A zone id the bundled tzdata has never heard of
      // would otherwise throw from inside the due list, one lazy field deep.
      schedule.location;
      return schedule;
    } on FormatException {
      return null;
    } on tz.LocationNotFoundException {
      return null;
    }
  }

  Completion _toCompletion(CompletionRow row) => Completion(
    id: row.id,
    taskId: row.taskId,
    completedAt: row.completedAt,
    source: row.source,
    note: row.note,
    deviceId: row.deviceId,
    createdAt: row.createdAt,
    deletedAt: row.deletedAt,
  );
}
