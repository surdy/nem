import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nem/src/app/clock.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/binding_repository.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/binding.dart';
import 'package:nem/src/domain/completion.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/target.dart';
import 'package:nem/src/nfc/tag_gateway.dart';
import 'package:nem/src/ui/scan_screen.dart';

import '../nfc/fake_tag_gateway.dart';
import '../notifications/fake_reminder_notifier.dart';

void main() {
  late NemDatabase db;
  late TargetRepository targets;
  late TaskRepository tasks;
  late BindingRepository bindings;
  late Target boiler;

  /// The scan flow measures elapsed time, so the clock has to move.
  late DateTime clock;

  /// Feeds a raw value into the screen the way the camera would.
  late ValueChanged<String> scan;

  /// Every haptic the screen asked the OS for.
  late List<String> haptics;

  /// The NFC hardware, in software: the second reader this screen owns.
  late FakeTagGateway tags;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    targets = TargetRepository(db);
    tasks = TaskRepository(db);
    bindings = BindingRepository(db);
    clock = DateTime(2026, 6, 15, 10);
    boiler = await targets.createTarget(name: 'The boiler');
    haptics = [];
    tags = FakeTagGateway();
  });

  tearDown(() => db.close());

  Future<void> pumpScan(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add('${call.arguments}');
        }
        return null;
      },
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
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          nowProvider.overrideWithValue(clock),
          clockProvider.overrideWithValue(() => clock),
          tagGatewayProvider.overrideWithValue(tags),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    // The camera is the one thing a test cannot have, so it is
                    // the one thing injected. Everything below this line —
                    // resolution, completion, the sheets, undo — is the code
                    // that ships.
                    builder: (_) => ScanScreen(
                      previewBuilder: (context, onScanned) {
                        scan = onScanned;
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ),
                child: const Text('Open the scanner'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open the scanner'));
    await tester.pumpAndSettle();
  }

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  Future<void> labelTheBoiler() => bindings.generateLabel(boiler.id);

  /// The boiler wearing a tag rather than a printed label. The stored value is
  /// the same uuid either way — the kind is the whole difference.
  Future<void> tagTheBoiler() => bindings.bind(
    targetId: boiler.id,
    kind: BindingKind.tag,
    value: boiler.id,
  );

  Future<void> overdueTask(String title) => tasks.createFloatingTask(
    title: title,
    targetId: boiler.id,
    intervalN: 30,
    intervalUnit: IntervalUnit.day,
    // Due 1 June 2026, a fortnight before the pinned clock.
    startDate: DateTime(2026, 5, 2),
  );

  Future<List<Completion>> completionsOf(String title) async {
    final task = (await tasks.allTasks()).firstWhere((t) => t.title == title);
    return tasks.completionsFor(task.id);
  }

  testWidgets('one task due completes immediately, with a haptic, a toast '
      'and five seconds of undo', (tester) async {
    await labelTheBoiler();
    await overdueTask('Bleed the radiators');

    await pumpScan(tester);
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();

    final completions = await completionsOf('Bleed the radiators');
    expect(completions.length, 1);
    // The completion knows it came off a printed label, not off a tag and not
    // off the due list.
    expect(completions.single.source, CompletionSource.label);

    expect(haptics, isNotEmpty);
    expect(
      find.text('Completed Bleed the radiators at The boiler'),
      findsOneWidget,
    );
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 5),
    );
    // And the scan screen is gone, so the due list is what updates underneath.
    expect(find.text('Scan'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('undo takes that completion back', (tester) async {
    await labelTheBoiler();
    await overdueTask('Bleed the radiators');

    await pumpScan(tester);
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(await completionsOf('Bleed the radiators'), isEmpty);
    await unmount(tester);
  });

  testWidgets('two due are listed in a sheet and ticked one at a time', (
    tester,
  ) async {
    await labelTheBoiler();
    await overdueTask('Bleed the radiators');
    await overdueTask('Check the pressure');

    await pumpScan(tester);
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();

    // Nothing is completed by the sheet appearing.
    expect(find.text('Due at The boiler'), findsOneWidget);
    expect(await completionsOf('Bleed the radiators'), isEmpty);
    expect(await completionsOf('Check the pressure'), isEmpty);

    await tester.tap(find.text('Bleed the radiators'));
    await tester.pumpAndSettle();

    expect(
      (await completionsOf('Bleed the radiators')).single.source,
      CompletionSource.label,
    );
    expect(await completionsOf('Check the pressure'), isEmpty);

    // The tick is its own undo.
    await tester.tap(find.text('Bleed the radiators'));
    await tester.pumpAndSettle();
    expect(await completionsOf('Bleed the radiators'), isEmpty);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('nothing due shows the target and completes nothing', (
    tester,
  ) async {
    await labelTheBoiler();
    // Due 1 July 2026 — upcoming at the pinned clock, so the scan must not
    // touch it (PLAN.md: no completion when nothing is due).
    await tasks.createFloatingTask(
      title: 'Service the boiler',
      targetId: boiler.id,
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    await pumpScan(tester);
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();

    expect(find.text('The boiler'), findsOneWidget);
    expect(find.text('Service the boiler'), findsOneWidget);
    expect(find.textContaining('Due 1 Jul 2026'), findsOneWidget);
    expect(await completionsOf('Service the boiler'), isEmpty);
    expect(haptics, isEmpty);

    await unmount(tester);
  });

  testWidgets('an unrecognised code offers to bind it to a target', (
    tester,
  ) async {
    await overdueTask('Bleed the radiators');

    await pumpScan(tester);
    scan('5010358210016');
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Bind 5010358210016 to a target'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('bind-to-${boiler.id}')));
    await tester.pumpAndSettle();

    final binding = await bindings.findBinding(
      BindingKind.barcode,
      '5010358210016',
    );
    expect(binding?.targetId, boiler.id);
    // Binding is not completing: the barcode was unknown a moment ago, and
    // silently ticking work off the back of it would be a surprise.
    expect(await completionsOf('Bleed the radiators'), isEmpty);
    expect(find.textContaining('Barcode bound to The boiler'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('an unrecognised code can make the target it binds to', (
    tester,
  ) async {
    // A barcode on a product is usually scanned before anybody has thought to
    // create the thing it is stuck to, and sending them away to the targets
    // screen would mean scanning it twice.
    await pumpScan(tester);
    scan('5010358210016');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bind-to-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-target-name')),
      'The water filter',
    );
    await tester.tap(find.byKey(const ValueKey('create-target')));
    await tester.pumpAndSettle();

    final created = (await targets.allTargets()).firstWhere(
      (target) => target.name == 'The water filter',
    );
    final binding = await bindings.findBinding(
      BindingKind.barcode,
      '5010358210016',
    );
    expect(binding?.targetId, created.id);
    expect(
      find.textContaining('Barcode bound to The water filter'),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('a label nobody bound is unrecognised too', (tester) async {
    await pumpScan(tester);
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unrecognised label'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a repeat scan of the same target within thirty seconds is '
      'ignored', (tester) async {
    await labelTheBoiler();
    await overdueTask('Bleed the radiators');
    await overdueTask('Check the pressure');

    await pumpScan(tester);
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    clock = clock.add(const Duration(seconds: 20));
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();
    expect(find.text('Due at The boiler'), findsNothing);

    // And past the window it resolves again.
    clock = clock.add(const Duration(seconds: 11));
    scan(labelUriFor(boiler.id));
    await tester.pumpAndSettle();
    expect(find.text('Due at The boiler'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  group('tags', () {
    testWidgets('a tag read completes the work due there, sourced to the tag', (
      tester,
    ) async {
      await tagTheBoiler();
      await overdueTask('Bleed the radiators');

      await pumpScan(tester);
      // Android polls under the camera, so the session is already open and the
      // tag arrives without anybody tapping anything.
      expect(tags.reading, isTrue);
      tags.present(TagValueRead(labelUriFor(boiler.id)));
      await tester.pumpAndSettle();

      final completions = await completionsOf('Bleed the radiators');
      expect(completions.length, 1);
      // The criterion: a completion recorded off a tag says so, and the only
      // thing that could have told it is the reader the screen passed in.
      expect(completions.single.source, CompletionSource.tag);
      expect(haptics, isNotEmpty);
      expect(
        find.text('Completed Bleed the radiators at The boiler'),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('the same URI off a tag does not resolve a label binding', (
      tester,
    ) async {
      // `nem://t/<uuid>` is byte-identical on a tag and on a printed label
      // (ADR 0009), and the reader is the only thing that separates them. A
      // boiler that has only ever been labelled has no tag bound, so a tag
      // carrying its URI is a code nem does not know yet.
      await labelTheBoiler();
      await overdueTask('Bleed the radiators');

      await pumpScan(tester);
      tags.present(TagValueRead(labelUriFor(boiler.id)));
      await tester.pumpAndSettle();

      expect(find.textContaining('Unrecognised tag'), findsOneWidget);
      expect(await completionsOf('Bleed the radiators'), isEmpty);

      // And binding it from here binds a tag, not a second label.
      await tester.tap(find.byKey(ValueKey('bind-to-${boiler.id}')));
      await tester.pumpAndSettle();
      expect(
        (await bindings.findBinding(BindingKind.tag, boiler.id))?.targetId,
        boiler.id,
      );

      await unmount(tester);
    });

    testWidgets('a tag nem did not write is offered for binding by its own '
        'payload', (tester) async {
      await pumpScan(tester);
      tags.present(const TagValueRead('https://example.com/filter'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Bind https://example.com/filter to a target'),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('a tag with nothing readable on it says so and completes '
        'nothing', (tester) async {
      await tagTheBoiler();
      await overdueTask('Bleed the radiators');

      await pumpScan(tester);
      tags.present(const TagUnreadable('This tag holds no NDEF data'));
      await tester.pumpAndSettle();

      expect(find.text('This tag holds no NDEF data'), findsOneWidget);
      expect(await completionsOf('Bleed the radiators'), isEmpty);

      await unmount(tester);
    });

    testWidgets('a phone with no NFC in it still scans labels, and offers no '
        'tag affordance at all', (tester) async {
      tags.available = TagAvailability.unsupported;
      await labelTheBoiler();
      await overdueTask('Bleed the radiators');

      await pumpScan(tester);
      expect(tags.reading, isFalse);
      expect(find.byKey(const ValueKey('scan-tag')), findsNothing);
      // Degrading gracefully is the camera behaving exactly as it always did,
      // with nothing on screen apologising for a radio this phone never had.
      expect(find.textContaining('NFC'), findsNothing);

      scan(labelUriFor(boiler.id));
      await tester.pumpAndSettle();
      expect((await completionsOf('Bleed the radiators')).length, 1);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('NFC switched off is said out loud, because the fix is one '
        'toggle away', (tester) async {
      tags.available = TagAvailability.disabled;
      await pumpScan(tester);

      expect(tags.reading, isFalse);
      expect(find.textContaining('NFC is switched off'), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-tag')), findsNothing);

      await unmount(tester);
    });

    testWidgets('where the session takes the screen over it waits for a tap, '
        'and closes itself again afterwards', (tester) async {
      // iOS: Core NFC raises the system's own sheet, and raising it uninvited
      // over a live camera would make the camera unusable (ADR 0009 — iPhone
      // scanning is two gestures).
      tags.presentation = TagSessionPresentation.systemSheet;
      await tagTheBoiler();
      await overdueTask('Bleed the radiators');

      await pumpScan(tester);
      expect(tags.reading, isFalse);

      await tester.tap(find.byKey(const ValueKey('scan-tag')));
      await tester.pumpAndSettle();
      expect(tags.reading, isTrue);

      tags.present(TagValueRead(labelUriFor(boiler.id)));
      await tester.pumpAndSettle();

      // The sheet comes down before nem shows anything of its own behind it.
      expect(tags.stopped.single.message, 'Tag read');
      expect(
        (await completionsOf('Bleed the radiators')).single.source,
        CompletionSource.tag,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('leaving the screen stops the session', (tester) async {
      await pumpScan(tester);
      expect(tags.reading, isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(tags.reading, isFalse);
      await unmount(tester);
    });
  });

  group('barcodes', () {
    /// A product code already printed on the boiler's filter box.
    Future<void> barcodeTheBoiler([String value = '5010358210016']) => bindings
        .bind(targetId: boiler.id, kind: BindingKind.barcode, value: value);

    test('the camera asks for the product symbologies #10 lists, and for '
        'ean13 whatever else it asks for', () {
      expect(
        scanFormats,
        containsAll(<BarcodeFormat>[
          BarcodeFormat.ean8,
          BarcodeFormat.ean13,
          BarcodeFormat.upcA,
          BarcodeFormat.upcE,
          BarcodeFormat.code128,
        ]),
      );
      // Apple's Vision framework has no UPC-A symbology: asking for `upcA`
      // alone finds nothing on an iPhone, and reports no error either. UPC-A
      // arrives there as an EAN-13, so `ean13` is what makes it detectable at
      // all — the criterion the issue's comment amended.
      expect(scanFormats, contains(BarcodeFormat.ean13));
      // And nem's own labels still have to scan.
      expect(scanFormats, contains(BarcodeFormat.qrCode));
    });

    testWidgets('a bound barcode resolves through the same flow as a label, '
        'and its completion is sourced to the barcode', (tester) async {
      await barcodeTheBoiler();
      await overdueTask('Change the filter');

      await pumpScan(tester);
      scan('5010358210016');
      await tester.pumpAndSettle();

      final completions = await completionsOf('Change the filter');
      expect(completions.length, 1);
      expect(completions.single.source, CompletionSource.barcode);
      expect(haptics, isNotEmpty);
      expect(
        find.text('Completed Change the filter at The boiler'),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('two due at a barcode are listed, and each tick is sourced to '
        'the barcode', (tester) async {
      await barcodeTheBoiler();
      await overdueTask('Change the filter');
      await overdueTask('Descale it');

      await pumpScan(tester);
      scan('5010358210016');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Descale it'));
      await tester.pumpAndSettle();
      expect(
        (await completionsOf('Descale it')).single.source,
        CompletionSource.barcode,
      );

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('a barcode bound on Android resolves off an iPhone, which '
        'reads the same UPC-A as an EAN-13', (tester) async {
      // MLKit reports the twelve digits under the bars; Vision has no UPC-A
      // and reports them behind a leading zero. Without canonicalisation the
      // second string simply would not find the first one's binding.
      await barcodeTheBoiler('036000291452');
      await overdueTask('Change the filter');

      await pumpScan(tester);
      scan('0036000291452');
      await tester.pumpAndSettle();

      expect(
        (await completionsOf('Change the filter')).single.source,
        CompletionSource.barcode,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('and the other way round: bound off an iPhone, scanned on '
        'Android', (tester) async {
      await pumpScan(tester);
      // Bound here as iOS reads it, which stores the canonical twelve digits.
      scan('0036000291452');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('bind-to-${boiler.id}')));
      await tester.pumpAndSettle();

      expect(
        (await bindings.findBinding(
          BindingKind.barcode,
          '036000291452',
        ))?.targetId,
        boiler.id,
      );

      await overdueTask('Change the filter');
      clock = clock.add(const Duration(minutes: 1));
      // And read on Android, where the same box gives twelve digits.
      scan('036000291452');
      await tester.pumpAndSettle();

      expect(
        (await completionsOf('Change the filter')).single.source,
        CompletionSource.barcode,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await unmount(tester);
    });

    testWidgets('a barcode claimed while the sheet was open is refused rather '
        'than taken over', (tester) async {
      await pumpScan(tester);
      scan('5010358210016');
      await tester.pumpAndSettle();
      expect(find.textContaining('Bind 5010358210016'), findsOneWidget);

      // The other half of a sync pull, or the same box bound from another
      // screen: between the sheet opening and the tap, the code became the
      // front door's.
      final door = await targets.createTarget(name: 'The front door');
      await bindings.bind(
        targetId: door.id,
        kind: BindingKind.barcode,
        value: '5010358210016',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('bind-to-${boiler.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('bind-refused')), findsOneWidget);
      expect(
        find.textContaining('already bound to The front door'),
        findsOneWidget,
      );
      expect(
        (await bindings.findBinding(
          BindingKind.barcode,
          '5010358210016',
        ))?.targetId,
        door.id,
      );

      await unmount(tester);
    });
  });
}
