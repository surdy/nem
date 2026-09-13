import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/binding_repository.dart';
import 'package:nem/src/data/category_repository.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/binding.dart';
import 'package:nem/src/domain/completion.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/scan.dart';
import 'package:nem/src/sync/sync_engine.dart';
import 'package:nem/src/sync/sync_settings.dart';

import 'fake_sync_transport.dart';

/// Two phones and one backend (#12).
///
/// Every test here is about the *pair*: what one device does offline, what the
/// other sees once both have synced, and whether the two agree afterwards.
/// Nothing here reaches a network — both devices push and pull through one
/// [FakeSyncTransport], which decides every write with the same
/// `localSupersedes` the real transport encodes into its PostgREST filters.
///
/// Convergence is asserted on the *stored* `due_date` column rather than on the
/// domain object, deliberately. `Task.dueDate` is computed from the schedule
/// and the log every time it is read, so it would agree across two devices even
/// if nothing ever recomputed the cache; the column is the thing ADR 0004 says
/// must be rewritten after every pull, and the due list sorts on it.
void main() {
  const backend = 'https://nem.supabase.co';

  late FakeSyncTransport transport;
  late _Device deviceA;
  late _Device deviceB;

  setUpAll(() {
    // Two devices means two `NemDatabase` instances, which is the thing this
    // whole file is about. They are separate in-memory databases behind
    // separate executors, so drift's warning about sharing one is noise here.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() async {
    transport = FakeSyncTransport();
    deviceA = await _Device.open(transport, backend);
    deviceB = await _Device.open(transport, backend);
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  /// A floating task on [device], repeating every thirty days.
  Future<String> createTask(
    _Device device, {
    String title = 'Replace the water filter',
    String? targetId,
    DateTime? now,
  }) async {
    final task = await device.tasks.createFloatingTask(
      title: title,
      targetId: targetId,
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
      now: now ?? DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  /// Both devices sync until neither has anything left to say.
  ///
  /// Three passes rather than two: the first device pushes before the second
  /// has, so it cannot pull what the second is still holding. Push-then-pull
  /// means one round each is never enough for a change made on both sides.
  Future<void> syncBoth() async {
    await deviceA.engine.sync();
    await deviceB.engine.sync();
    await deviceA.engine.sync();
  }

  group('two devices that each recorded completions offline', () {
    test('converge on the same due date', () async {
      final id = await createTask(deviceA);
      await deviceA.engine.sync();
      await deviceB.engine.sync();
      expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 1, 9));

      // Both go quiet, and the work happens on whichever phone is to hand.
      // Interleaved on purpose: neither device's completions are a contiguous
      // block, so a merge that took "the newer device's log" rather than the
      // union of both would be caught here.
      await deviceA.tasks.recordCompletion(
        id,
        completedAt: DateTime(2026, 6, 5, 9),
        now: DateTime(2026, 6, 5, 9),
      );
      await deviceB.tasks.recordCompletion(
        id,
        completedAt: DateTime(2026, 6, 8, 9),
        now: DateTime(2026, 6, 8, 9),
      );
      await deviceA.tasks.recordCompletion(
        id,
        completedAt: DateTime(2026, 6, 10, 9),
        now: DateTime(2026, 6, 10, 9),
      );
      await deviceB.tasks.recordCompletion(
        id,
        completedAt: DateTime(2026, 6, 12, 9),
        now: DateTime(2026, 6, 12, 9),
      );

      // Before either syncs they disagree, and both are right about what they
      // know: A last saw the work done on the 10th, B on the 12th.
      expect(await deviceA.storedDueDate(id), DateTime(2026, 7, 10, 9));
      expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 12, 9));

      await syncBoth();

      // No conflict resolution happened, because none was needed: the log is
      // append-only, so the merge is the union (ADR 0004).
      expect(await deviceA.completedDates(id), [
        DateTime(2026, 6, 5, 9),
        DateTime(2026, 6, 8, 9),
        DateTime(2026, 6, 10, 9),
        DateTime(2026, 6, 12, 9),
      ]);
      expect(
        await deviceB.completedDates(id),
        await deviceA.completedDates(id),
      );

      // And the due date each phone will sort its list by is the same one.
      expect(await deviceA.storedDueDate(id), DateTime(2026, 7, 12, 9));
      expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 12, 9));
    });

    test('keep both copies of a completion neither of them edited', () async {
      final id = await createTask(deviceA);
      await deviceA.engine.sync();
      await deviceB.engine.sync();

      final onA = await deviceA.tasks.recordCompletion(
        id,
        completedAt: DateTime(2026, 6, 5, 9),
        now: DateTime(2026, 6, 5, 9),
      );
      await syncBoth();

      // The far device's copy is the same row, not a second one — an
      // append-only log merges by id, so two devices holding one completion is
      // one completion (ADR 0004).
      final theirs = (await deviceB.tasks.completionsFor(id)).single;
      expect(theirs.id, onA.id);
      expect(theirs.deviceId, onA.deviceId, reason: 'A recorded it, not B');
      expect(theirs.completedAt, onA.completedAt);
      expect(theirs.updatedAt, onA.updatedAt);

      // Nothing supersedes anything on a further sync: the clocks are equal, so
      // neither copy wins and both stay exactly as they are.
      final report = await deviceB.engine.sync();
      expect(report.pulled, 0);
      expect(report.pushed, 0);
    });
  });

  test('a correction made on one device reaches the other', () async {
    final id = await createTask(deviceA);
    await deviceA.engine.sync();
    await deviceB.engine.sync();

    final completion = await deviceA.tasks.recordCompletion(
      id,
      completedAt: DateTime(2026, 6, 5, 9),
      now: DateTime(2026, 6, 5, 9),
    );
    await deviceA.tasks.recordCompletion(
      id,
      completedAt: DateTime(2026, 6, 12, 9),
      now: DateTime(2026, 6, 12, 9),
    );
    await syncBoth();
    expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 12, 9));

    // Both cursors are now past both completions' `created_at`. This is the
    // case a cursor on `created_at` could never carry: taking a completion back
    // moves `deleted_at` and leaves `created_at` alone, so the corrected row
    // would sit behind B's cursor forever and B would go on believing work
    // happened that did not.
    final later = (await deviceA.tasks.completionsFor(id)).first;
    expect(later.completedAt, DateTime(2026, 6, 12, 9));
    await deviceA.tasks.undoCompletion(later, now: DateTime(2026, 6, 13, 11));

    await syncBoth();

    // The tombstone crossed, so the earlier completion is what both devices now
    // measure from.
    expect(await deviceB.completedDates(id), [DateTime(2026, 6, 5, 9)]);
    expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 5, 9));
    expect(await deviceA.storedDueDate(id), DateTime(2026, 7, 5, 9));

    // The row itself is still there on the far device, tombstoned rather than
    // gone — which is what stops B pushing its live copy back at A.
    final rows = await deviceB.db.select(deviceB.db.completions).get();
    expect(rows, hasLength(2));
    final byId = {for (final row in rows) row.id: row};
    expect(byId[completion.id]!.deletedAt, isNull);
    expect(byId[later.id]!.deletedAt, DateTime(2026, 6, 13, 11));
    expect(
      byId[later.id]!.updatedAt,
      DateTime(2026, 6, 13, 11),
      reason: 'the clock moved with the tombstone, which is what carried it',
    );
  });

  test('derived due dates are recomputed after a pull, not only after a '
      'local write', () async {
    final id = await createTask(deviceA);
    await deviceA.engine.sync();
    await deviceB.engine.sync();
    expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 1, 9));

    await deviceA.tasks.recordCompletion(
      id,
      completedAt: DateTime(2026, 6, 5, 9),
      now: DateTime(2026, 6, 5, 9),
    );
    await deviceA.engine.sync();

    // B writes nothing at all. The only thing that happens on it is a pull, and
    // the cache has to move anyway (ADR 0004) — the completion that invalidated
    // it was recorded on the other phone, and nothing local will ever touch
    // this row again.
    final report = await deviceB.engine.pull();

    expect(report.pulled, greaterThan(0));
    expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 5, 9));
    expect(
      await deviceB.storedLastCompletedAt(id),
      DateTime(2026, 6, 5, 9),
      reason: 'the other cache derived from the log moves too',
    );
  });

  test('a completion that arrives before its task is kept', () async {
    // The hazard the version 7 migration exists for (ADR 0011). The backend
    // holds a completion whose task is not there — a push that was refused, a
    // drain that died halfway, or simply a device that has not got to it — and
    // a pull must take the completion anyway. Completions are the one thing nem
    // cannot afford to lose (ADR 0004).
    final id = await createTask(deviceA);
    final completion = await deviceA.tasks.recordCompletion(
      id,
      completedAt: DateTime(2026, 6, 5, 9),
      now: DateTime(2026, 6, 5, 9),
    );
    await deviceA.engine.drainOutbox();
    transport.tables['tasks']!.remove(id);

    final report = await deviceB.engine.pull();

    expect(report.isComplete, isTrue);
    expect(await deviceB.tasks.allTasks(), isEmpty);
    final orphan =
        (await deviceB.db.select(deviceB.db.completions).get()).single;
    expect(orphan.id, completion.id);
    expect(orphan.taskId, id);

    // And once the task turns up, the orphan is simply part of the log: the due
    // date it implies appears without the completion being sent again.
    await deviceA.outboxTask(id);
    await deviceA.engine.drainOutbox();
    await deviceB.engine.pull();

    expect((await deviceB.tasks.allTasks()).single.id, id);
    expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 5, 9));
  });

  group('targets and bindings', () {
    test('a label provisioned on one device resolves a scan on the '
        'other', () async {
      final target = await deviceA.targets.createTarget(
        name: 'The boiler',
        now: DateTime(2026, 6, 1, 9),
      );
      final id = await createTask(
        deviceA,
        title: 'Bleed the radiators',
        targetId: target.id,
      );
      final label = await deviceA.bindings.generateLabel(
        target.id,
        now: DateTime(2026, 6, 1, 9),
      );
      await syncBoth();

      // B has never seen this target, this task or this label, and the printed
      // QR code resolves there exactly as it does here.
      final outcome = await deviceB.resolver.resolve(
        labelUriFor(target.id),
        now: DateTime(2026, 7, 2, 9),
      );

      expect(outcome, isA<ScanOneTaskDue>());
      final due = outcome as ScanOneTaskDue;
      expect(due.target.name, 'The boiler');
      expect(due.task.id, id);
      expect(due.code.kind, BindingKind.label);
      expect(
        (await deviceB.bindings.bindingsForTarget(target.id)).single.id,
        label.id,
      );
    });

    test('a scan recorded on one device reschedules the task on the '
        'other', () async {
      final target = await deviceA.targets.createTarget(
        name: 'The boiler',
        now: DateTime(2026, 6, 1, 9),
      );
      final id = await createTask(
        deviceA,
        title: 'Bleed the radiators',
        targetId: target.id,
      );
      await deviceA.bindings.generateLabel(
        target.id,
        now: DateTime(2026, 6, 1, 9),
      );
      await syncBoth();

      // The work is done at the boiler, with B's phone in hand.
      await deviceB.tasks.recordCompletion(
        id,
        source: CompletionSource.label,
        completedAt: DateTime(2026, 7, 2, 9),
        now: DateTime(2026, 7, 2, 9),
      );
      await syncBoth();

      final onA = (await deviceA.tasks.completionsFor(id)).single;
      expect(onA.source, CompletionSource.label);
      expect(onA.completedAt, DateTime(2026, 7, 2, 9));
      expect(await deviceA.storedDueDate(id), DateTime(2026, 8, 1, 9));
      expect(await deviceB.storedDueDate(id), DateTime(2026, 8, 1, 9));
    });

    test('unbinding a code on one device stops it resolving on the '
        'other', () async {
      final target = await deviceA.targets.createTarget(
        name: 'The boiler',
        now: DateTime(2026, 6, 1, 9),
      );
      final label = await deviceA.bindings.generateLabel(
        target.id,
        now: DateTime(2026, 6, 1, 9),
      );
      await syncBoth();
      expect(
        await deviceB.bindings.findBinding(BindingKind.label, target.id),
        isNotNull,
      );

      await deviceA.bindings.unbind(label.id, now: DateTime(2026, 6, 2, 9));
      await syncBoth();

      expect(
        await deviceB.bindings.findBinding(BindingKind.label, target.id),
        isNull,
      );
      // A dangling code is an unknown code, not an error (ADR 0011).
      expect(
        await deviceB.resolver.resolve(
          labelUriFor(target.id),
          now: DateTime(2026, 6, 3, 9),
        ),
        isA<ScanUnknownCode>(),
      );
    });

    test('deleting a target on one device unassigns its tasks on the '
        'other', () async {
      final target = await deviceA.targets.createTarget(
        name: 'The boiler',
        now: DateTime(2026, 6, 1, 9),
      );
      final id = await createTask(deviceA, targetId: target.id);
      await syncBoth();
      expect((await deviceB.tasks.allTasks()).single.targetId, target.id);

      await deviceA.targets.softDeleteTarget(
        target.id,
        now: DateTime(2026, 6, 2, 9),
      );
      await syncBoth();

      expect(await deviceB.targets.allTargets(), isEmpty);
      expect((await deviceB.tasks.allTasks()).single.id, id);
      expect((await deviceB.tasks.allTasks()).single.targetId, isNull);
    });
  });

  group('categories', () {
    test('a category made on one device turns up on the other, with its '
        'colour', () async {
      final kitchen = await deviceA.categories.createCategory(
        name: 'Kitchen',
        color: 0xFF4285F4,
        now: DateTime(2026, 6, 1, 9),
      );

      await syncBoth();

      final arrived = (await deviceB.categories.allCategories()).single;
      expect(arrived.id, kitchen.id);
      expect(arrived.name, 'Kitchen');
      expect(arrived.color, 0xFF4285F4);
    });

    test(
      'a rename on one device wins over an older name on the other',
      () async {
        final kitchen = await deviceA.categories.createCategory(
          name: 'Kitchen',
          now: DateTime(2026, 6, 1, 9),
        );
        await syncBoth();

        await deviceB.categories.updateCategory(
          id: kitchen.id,
          name: 'The kitchen',
          color: 0xFF34A853,
          now: DateTime(2026, 6, 3, 9),
        );
        await deviceA.categories.updateCategory(
          id: kitchen.id,
          name: 'Kitchen cupboard',
          now: DateTime(2026, 6, 2, 9),
        );
        await syncBoth();

        // Last write wins on `updated_at`, as for everything that is not a
        // completion (PLAN.md — Sync).
        for (final device in [deviceA, deviceB]) {
          final stored = (await device.categories.allCategories()).single;
          expect(stored.name, 'The kitchen');
          expect(stored.color, 0xFF34A853);
        }
      },
    );

    test('a task put in two categories on one device is in both on the '
        'other', () async {
      final kitchen = await deviceA.categories.createCategory(
        name: 'Kitchen',
        now: DateTime(2026, 6, 1, 9),
      );
      final admin = await deviceA.categories.createCategory(
        name: 'Admin',
        now: DateTime(2026, 6, 1, 9),
      );
      final id = await createTask(deviceA);
      await deviceA.categories.setCategoriesForTask(id, {
        kitchen.id,
        admin.id,
      }, now: DateTime(2026, 6, 1, 10));

      await syncBoth();

      expect(
        (await deviceB.categories.categoriesForTask(id)).map((c) => c.name),
        ['Admin', 'Kitchen'],
      );
      // And the filtered due list on the far device agrees.
      expect(
        (await deviceB.tasks.watchDueList(categoryIds: {kitchen.id}).first)
            .single
            .id,
        id,
      );
    });

    test('taking a task out of a category on one device takes it out on the '
        'other', () async {
      final kitchen = await deviceA.categories.createCategory(
        name: 'Kitchen',
        now: DateTime(2026, 6, 1, 9),
      );
      final id = await createTask(deviceA);
      await deviceA.categories.setCategoriesForTask(id, {
        kitchen.id,
      }, now: DateTime(2026, 6, 1, 10));
      await syncBoth();
      expect(await deviceB.categories.categoriesForTask(id), hasLength(1));

      await deviceA.categories.setCategoriesForTask(
        id,
        const {},
        now: DateTime(2026, 6, 2, 9),
      );
      await syncBoth();

      expect(await deviceB.categories.categoriesForTask(id), isEmpty);
      // The membership row is tombstoned on both, not deleted on either — a
      // hard delete on one is what would let the other resurrect it.
      for (final device in [deviceA, deviceB]) {
        final rows = await device.db.select(device.db.taskCategories).get();
        expect(rows, hasLength(1));
        expect(rows.single.deletedAt, isNotNull);
      }
    });

    test('deleting a category on one device empties it on the other and '
        'leaves the tasks alone', () async {
      final kitchen = await deviceA.categories.createCategory(
        name: 'Kitchen',
        now: DateTime(2026, 6, 1, 9),
      );
      final id = await createTask(deviceA);
      await deviceA.categories.setCategoriesForTask(id, {
        kitchen.id,
      }, now: DateTime(2026, 6, 1, 10));
      await syncBoth();

      await deviceA.categories.softDeleteCategory(
        kitchen.id,
        now: DateTime(2026, 6, 2, 9),
      );
      await syncBoth();

      expect(await deviceB.categories.allCategories(), isEmpty);
      expect(await deviceB.categories.categoriesForTask(id), isEmpty);
      // The work survives the grouping, exactly as it survives a deleted
      // target.
      expect((await deviceB.tasks.allTasks()).single.id, id);
      expect(await deviceB.storedDueDate(id), DateTime(2026, 7, 1, 9));
    });

    test('a delete beats a rename made on the other device while it was '
        'offline', () async {
      final kitchen = await deviceA.categories.createCategory(
        name: 'Kitchen',
        now: DateTime(2026, 6, 1, 9),
      );
      await syncBoth();

      await deviceA.categories.softDeleteCategory(
        kitchen.id,
        now: DateTime(2026, 6, 2, 9),
      );
      // B has not seen the delete, and renames it later by the clock.
      await deviceB.categories.updateCategory(
        id: kitchen.id,
        name: 'The kitchen',
        now: DateTime(2026, 6, 3, 9),
      );
      await syncBoth();

      // A tombstone outranks every non-deleted version of the row, whatever
      // its timestamp (`sync_row.dart`).
      expect(await deviceA.categories.allCategories(), isEmpty);
      expect(await deviceB.categories.allCategories(), isEmpty);
    });

    test('a membership that arrives before its category is kept and resolves '
        'once the category lands', () async {
      // The ordering ADR 0011 is about: a pull delivers rows per table, and
      // nothing refuses a membership whose category has not arrived yet.
      final kitchen = await deviceA.categories.createCategory(
        name: 'Kitchen',
        now: DateTime(2026, 6, 1, 9),
      );
      final id = await createTask(deviceA);
      await deviceA.categories.setCategoriesForTask(id, {
        kitchen.id,
      }, now: DateTime(2026, 6, 1, 10));
      await deviceA.engine.sync();

      // B pulls the membership table only, then everything.
      await deviceB.engine.pull();
      expect(await deviceB.categories.categoriesForTask(id), hasLength(1));
    });
  });
}

/// One phone: its own database, its own cursors, its own outbox.
class _Device {
  _Device._(this.db, this.settings, this.tasks, this.engine)
    : targets = TargetRepository(db),
      bindings = BindingRepository(db),
      categories = CategoryRepository(db);

  static Future<_Device> open(
    FakeSyncTransport transport,
    String backend,
  ) async {
    final db = NemDatabase(NativeDatabase.memory());
    final settings = SyncSettingsRepository(db);
    await settings.write(
      SyncSettings(url: backend, anonKey: 'public-anon-key'),
    );
    final tasks = TaskRepository(db);
    return _Device._(
      db,
      settings,
      tasks,
      SyncEngine(
        db: db,
        transport: transport,
        settings: settings,
        tasks: tasks,
      ),
    );
  }

  final NemDatabase db;
  final SyncSettingsRepository settings;
  final TaskRepository tasks;
  final SyncEngine engine;
  final TargetRepository targets;
  final BindingRepository bindings;
  final CategoryRepository categories;

  late final ScanResolver resolver = ScanResolver(
    RepositoryScanLookup(bindings: bindings, targets: targets, tasks: tasks),
  );

  /// The cached due date as it is stored — what the due list sorts on, and what
  /// a pull has to rewrite (ADR 0004).
  Future<DateTime?> storedDueDate(String taskId) async => (await (db.select(
    db.tasks,
  )..where((t) => t.id.equals(taskId))).getSingle()).dueDate;

  Future<DateTime?> storedLastCompletedAt(String taskId) async =>
      (await (db.select(
        db.tasks,
      )..where((t) => t.id.equals(taskId))).getSingle()).lastCompletedAt;

  /// When the surviving completions say the work was done, oldest first.
  Future<List<DateTime>> completedDates(String taskId) async {
    final log = await tasks.completionsFor(taskId);
    return [for (final completion in log.reversed) completion.completedAt];
  }

  /// Queues the task row again, standing in for the push that had not happened
  /// yet when a completion reached the backend first.
  Future<void> outboxTask(String taskId) =>
      engine.outbox.enqueue('tasks', taskId, now: DateTime(2026, 6, 6, 9));

  Future<void> close() => db.close();
}
