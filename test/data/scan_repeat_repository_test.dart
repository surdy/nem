import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/scan_repeat_repository.dart';
import 'package:nem/src/domain/scan.dart';

void main() {
  late NemDatabase db;
  late ScanRepeatRepository repository;

  final epoch = DateTime(2026, 6, 15, 10, 30, 15);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = ScanRepeatRepository(db);
  });

  tearDown(() => db.close());

  test('nothing stored is no window', () async {
    expect(await repository.read(), isNull);
  });

  test('an anchor survives being written and read back', () async {
    await repository.write(ScanRepeatAnchor(targetId: 'target-1', at: epoch));

    final anchor = await repository.read();
    expect(anchor?.targetId, 'target-1');
    // To the millisecond: the window is thirty seconds wide, so a second lost
    // in the round trip is three percent of it.
    expect(anchor?.at, epoch);
  });

  test('a second scan replaces the first rather than piling up', () async {
    await repository.write(ScanRepeatAnchor(targetId: 'target-1', at: epoch));
    await repository.write(
      ScanRepeatAnchor(
        targetId: 'target-2',
        at: epoch.add(const Duration(minutes: 5)),
      ),
    );

    final anchor = await repository.read();
    expect(anchor?.targetId, 'target-2');
    expect(anchor?.at, epoch.add(const Duration(minutes: 5)));
  });

  test('clearing it leaves no window behind', () async {
    await repository.write(ScanRepeatAnchor(targetId: 'target-1', at: epoch));
    await repository.clear();

    expect(await repository.read(), isNull);
  });

  test('a value that cannot be read is no window, not a crash', () async {
    // This is read on the launch path, where a tag has already been tapped and
    // something has to happen. Reverting to "no window" completes the work
    // again at worst; throwing would strand a person holding a phone.
    await db
        .into(db.syncState)
        .insertOnConflictUpdate(
          const SyncStateCompanion(
            key: Value('scan_repeat_target'),
            value: Value('target-1'),
          ),
        );
    await db
        .into(db.syncState)
        .insertOnConflictUpdate(
          const SyncStateCompanion(
            key: Value('scan_repeat_at'),
            value: Value('the day before yesterday'),
          ),
        );

    expect(await repository.read(), isNull);
  });

  test('a target with no timestamp is no window either', () async {
    await db
        .into(db.syncState)
        .insertOnConflictUpdate(
          const SyncStateCompanion(
            key: Value('scan_repeat_target'),
            value: Value('target-1'),
          ),
        );

    expect(await repository.read(), isNull);
  });

  test('the digest settings share the table and are left alone', () async {
    // Both live in `sync_state` (PLAN.md — device-local key/value state), and
    // clearing the window must not clear the digest with it.
    await db
        .into(db.syncState)
        .insertOnConflictUpdate(
          const SyncStateCompanion(
            key: Value('digest_enabled'),
            value: Value('true'),
          ),
        );

    await repository.write(ScanRepeatAnchor(targetId: 'target-1', at: epoch));
    await repository.clear();

    final row = await (db.select(
      db.syncState,
    )..where((s) => s.key.equals('digest_enabled'))).getSingleOrNull();
    expect(row?.value, 'true');
  });
}
