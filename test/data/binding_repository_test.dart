import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/binding_repository.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/binding.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/scan.dart';
import 'package:nem/src/domain/target.dart';

void main() {
  late NemDatabase db;
  late BindingRepository bindings;
  late TargetRepository targets;
  late TaskRepository tasks;
  late Target boiler;
  late Target door;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    bindings = BindingRepository(db);
    targets = TargetRepository(db);
    tasks = TaskRepository(db);
    boiler = await targets.createTarget(name: 'The boiler');
    door = await targets.createTarget(name: 'The front door');
  });

  tearDown(() => db.close());

  test('generating a label binds the target\'s own id', () async {
    final label = await bindings.generateLabel(boiler.id);

    expect(label.kind, BindingKind.label);
    expect(label.value, boiler.id);
    expect(label.targetId, boiler.id);
    expect(labelUriFor(label.value), 'nem://t/${boiler.id}');
  });

  test('generating the same label twice is one binding', () async {
    final first = await bindings.generateLabel(boiler.id);
    final second = await bindings.generateLabel(boiler.id);

    expect(second.id, first.id);
    expect((await bindings.bindingsForTarget(boiler.id)).length, 1);
  });

  test('a scanned label finds its target', () async {
    await bindings.generateLabel(boiler.id);

    final found = await bindings.findBinding(BindingKind.label, boiler.id);
    expect(found?.targetId, boiler.id);
  });

  test('kind and value together are the key: a tag and a label can carry '
      'the same uuid', () async {
    await bindings.generateLabel(boiler.id);
    await bindings.bind(
      targetId: boiler.id,
      kind: BindingKind.tag,
      value: boiler.id,
    );

    expect(
      (await bindings.findBinding(BindingKind.label, boiler.id))?.targetId,
      boiler.id,
    );
    expect(
      (await bindings.findBinding(BindingKind.tag, boiler.id))?.targetId,
      boiler.id,
    );
    expect((await bindings.bindingsForTarget(boiler.id)).length, 2);
  });

  test('binding a barcode keeps the raw code, trimmed', () async {
    final binding = await bindings.bind(
      targetId: door.id,
      kind: BindingKind.barcode,
      value: '  5010358210016 ',
    );

    expect(binding.kind, BindingKind.barcode);
    expect(binding.value, '5010358210016');
    expect(
      (await bindings.findBinding(
        BindingKind.barcode,
        '5010358210016',
      ))?.targetId,
      door.id,
    );
  });

  test('re-binding a code to another target re-points one row rather than '
      'failing the unique index', () async {
    final first = await bindings.bind(
      targetId: boiler.id,
      kind: BindingKind.barcode,
      value: '5010358210016',
    );
    final second = await bindings.bind(
      targetId: door.id,
      kind: BindingKind.barcode,
      value: '5010358210016',
    );

    expect(second.id, first.id);
    expect(second.targetId, door.id);
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);
    expect((await bindings.bindingsForTarget(door.id)).single.id, first.id);
  });

  test('unbinding stops the code resolving but keeps the row', () async {
    final binding = await bindings.bind(
      targetId: door.id,
      kind: BindingKind.barcode,
      value: '5010358210016',
    );
    await bindings.unbind(binding.id);

    expect(
      await bindings.findBinding(BindingKind.barcode, '5010358210016'),
      isNull,
    );
    expect(await bindings.bindingsForTarget(door.id), isEmpty);

    // Kept, not deleted: a hard delete would lose to the other device's copy
    // once sync arrives (PLAN.md — Sync).
    final rows = await db.select(db.bindings).get();
    expect(rows.single.deletedAt, isNotNull);
  });

  test('a code that was unbound can be bound again, to anything', () async {
    final binding = await bindings.bind(
      targetId: door.id,
      kind: BindingKind.barcode,
      value: '5010358210016',
    );
    await bindings.unbind(binding.id);
    final rebound = await bindings.bind(
      targetId: boiler.id,
      kind: BindingKind.barcode,
      value: '5010358210016',
    );

    expect(rebound.id, binding.id);
    expect(
      (await bindings.findBinding(
        BindingKind.barcode,
        '5010358210016',
      ))?.targetId,
      boiler.id,
    );
    expect((await db.select(db.bindings).get()).length, 1);
  });

  test('the codes on a target are watchable', () async {
    final seen = <int>[];
    final subscription = bindings
        .watchBindingsForTarget(boiler.id)
        .listen((rows) => seen.add(rows.length));

    await pumpEventQueue();
    await bindings.generateLabel(boiler.id);
    await pumpEventQueue();
    addTearDown(subscription.cancel);

    expect(seen.last, 1);
  });

  test('the lookup the resolver uses is wired to the real tables', () async {
    await bindings.generateLabel(boiler.id);
    await tasks.createFloatingTask(
      title: 'Bleed the radiators',
      targetId: boiler.id,
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 5, 1),
    );

    final resolver = ScanResolver(
      RepositoryScanLookup(bindings: bindings, targets: targets, tasks: tasks),
    );
    final outcome = await resolver.resolve(
      labelUriFor(boiler.id),
      now: DateTime(2026, 6, 15),
    );

    expect(outcome, isA<ScanOneTaskDue>());
    expect((outcome as ScanOneTaskDue).task.title, 'Bleed the radiators');
  });
}
