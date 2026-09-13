import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/binding_repository.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/domain/binding.dart';
import 'package:nem/src/domain/target.dart';
import 'package:nem/src/nfc/tag_gateway.dart';
import 'package:nem/src/ui/target_tag_screen.dart';

import '../nfc/fake_tag_gateway.dart';

void main() {
  late NemDatabase db;
  late TargetRepository targets;
  late BindingRepository bindings;
  late Target boiler;
  late FakeTagGateway tags;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    targets = TargetRepository(db);
    bindings = BindingRepository(db);
    boiler = await targets.createTarget(name: 'The boiler');
    tags = FakeTagGateway();
  });

  tearDown(() => db.close());

  Future<void> pumpTag(WidgetTester tester) async {
    // A successful write buzzes the phone, and an unanswered platform channel
    // in a widget test never completes — so the buzz has to be answered here
    // or the screen waits for it forever.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // The NFC hardware is the one thing a test cannot have. Everything
          // below this line — the capacity check, the binding, every message —
          // is the code that ships.
          tagGatewayProvider.overrideWithValue(tags),
        ],
        child: MaterialApp(home: TargetTagScreen(target: boiler)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  Future<void> write(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('write-tag')));
    await tester.pumpAndSettle();
  }

  testWidgets('writing a tag puts the target URI on it and binds it', (
    tester,
  ) async {
    await pumpTag(tester);
    await write(tester);

    // The tag carries exactly what the printed label encodes (ADR 0009).
    expect(tags.written, [labelUriFor(boiler.id)]);
    expect(find.textContaining('Written.'), findsOneWidget);

    // Provisioning is the write *and* the binding (CONTEXT.md).
    final binding = (await bindings.bindingsForTarget(boiler.id)).single;
    expect(binding.kind, BindingKind.tag);
    expect(binding.value, boiler.id);
    // Which is what makes a scan of it resolve — and it is a different row from
    // the label's, so a target can wear both.
    expect(
      (await bindings.findBinding(BindingKind.tag, boiler.id))?.id,
      binding.id,
    );
    expect(await bindings.findBinding(BindingKind.label, boiler.id), isNull);

    await unmount(tester);
  });

  testWidgets('a tag with insufficient capacity is its own outcome, and binds '
      'nothing', (tester) async {
    tags.writeOutcome = const TagTooSmall(needed: 52, capacity: 12);
    await pumpTag(tester);
    await write(tester);

    expect(find.textContaining('has not got the room'), findsOneWidget);
    expect(find.textContaining('52 bytes'), findsOneWidget);
    expect(find.textContaining('12'), findsOneWidget);
    // Nothing was written, so nothing may claim it was.
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);

    await unmount(tester);
  });

  testWidgets('a locked tag is told apart from a small one', (tester) async {
    tags.writeOutcome = const TagReadOnly();
    await pumpTag(tester);
    await write(tester);

    expect(find.textContaining('locked'), findsOneWidget);
    expect(find.textContaining('has not got the room'), findsNothing);
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);

    await unmount(tester);
  });

  testWidgets('an unformatted tag says which phone can deal with it', (
    tester,
  ) async {
    tags.writeOutcome = const TagUnformatted();
    await pumpTag(tester);
    await write(tester);

    expect(find.textContaining('never been formatted'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('any other failure is an unknown failure, and says try again', (
    tester,
  ) async {
    // Every thrown error lands here, including an over-capacity write that
    // slipped past the pre-check: the platform's exception cannot say which it
    // was, so neither does nem.
    tags.writeOutcome = const TagWriteFailed('IOException');
    await pumpTag(tester);
    await write(tester);

    expect(find.textContaining('Could not write the tag'), findsOneWidget);
    expect(find.text('IOException'), findsOneWidget);
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);

    await unmount(tester);
  });

  testWidgets('waiting for a tag can be cancelled, and stops the session', (
    tester,
  ) async {
    tags.pendingWrite = Completer<TagWriteOutcome>();
    await pumpTag(tester);
    // Pumped rather than settled: the screen is deliberately left waiting for a
    // tag that is never presented, and a spinner never settles.
    await tester.tap(find.byKey(const ValueKey('write-tag')));
    await tester.pump();

    expect(find.textContaining('Waiting for a tag'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cancel-tag')));
    await tester.pump();

    expect(tags.stopped, isNotEmpty);
    expect(find.byKey(const ValueKey('write-tag')), findsOneWidget);

    tags.pendingWrite!.complete(const TagWriteCancelled());
    await tester.pumpAndSettle();
    expect(find.text('No tag was written.'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a device with no NFC hardware offers a printed label instead', (
    tester,
  ) async {
    tags.available = TagAvailability.unsupported;
    await pumpTag(tester);

    expect(find.byKey(const ValueKey('tag-unsupported')), findsOneWidget);
    expect(find.byKey(const ValueKey('write-tag')), findsNothing);
    // Degrading is offering the thing that still works, not an apology.
    await tester.tap(find.byKey(const ValueKey('tag-use-label')));
    await tester.pumpAndSettle();
    expect(find.text('nem://t/${boiler.id}'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('NFC switched off says so, and notices when it is switched on', (
    tester,
  ) async {
    tags.available = TagAvailability.disabled;
    await pumpTag(tester);

    expect(find.byKey(const ValueKey('tag-disabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('write-tag')), findsNothing);

    // The point of a "check again" button: the fix happens outside nem.
    tags.available = TagAvailability.enabled;
    await tester.tap(find.byKey(const ValueKey('tag-recheck')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tag-disabled')), findsNothing);
    expect(find.byKey(const ValueKey('write-tag')), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('writing a second tag for the same target is one binding, not '
      'two', (tester) async {
    await pumpTag(tester);
    await write(tester);
    await write(tester);

    expect(tags.written.length, 2);
    expect((await bindings.bindingsForTarget(boiler.id)).length, 1);

    await unmount(tester);
  });
}
