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
import 'package:nem/src/ui/target_barcode_screen.dart';

void main() {
  late NemDatabase db;
  late TargetRepository targets;
  late BindingRepository bindings;
  late Target boiler;
  late Target car;

  /// Feeds a raw value into the screen the way the camera would.
  late ValueChanged<String> scan;

  late List<String> haptics;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    targets = TargetRepository(db);
    bindings = BindingRepository(db);
    boiler = await targets.createTarget(name: 'The boiler');
    car = await targets.createTarget(name: 'The car');
    haptics = [];
  });

  tearDown(() => db.close());

  Future<void> pumpBarcode(WidgetTester tester, {Target? target}) async {
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
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: TargetBarcodeScreen(
            target: target ?? boiler,
            // The camera is the one thing a test cannot have, so it is the one
            // thing injected. Everything below it — the parse, the
            // canonicalisation, the binding and the refusal — is what ships.
            previewBuilder: (context, onScanned) {
              scan = onScanned;
              return const SizedBox.shrink();
            },
          ),
        ),
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

  testWidgets('a product code on the thing binds to it, with nothing printed '
      'and nothing written', (tester) async {
    await pumpBarcode(tester);
    scan('5010358210016');
    await tester.pumpAndSettle();

    final binding = await bindings.findBinding(
      BindingKind.barcode,
      '5010358210016',
    );
    expect(binding?.targetId, boiler.id);
    expect(binding?.kind, BindingKind.barcode);
    expect(haptics, isNotEmpty);
    expect(
      find.textContaining('5010358210016 now resolves to The boiler'),
      findsOneWidget,
    );

    await unmount(tester);
  });

  testWidgets('the UPC-A an iPhone reports as an EAN-13 binds the same value '
      'an Android phone would', (tester) async {
    await pumpBarcode(tester);
    // Apple's Vision framework has no UPC-A symbology and reports the twelve
    // digits with a leading zero.
    scan('0036000291452');
    await tester.pumpAndSettle();

    expect(
      (await bindings.findBinding(
        BindingKind.barcode,
        '036000291452',
      ))?.targetId,
      boiler.id,
    );
    // And nothing was bound under the thirteen-digit form, which is what would
    // have left the two phones unable to resolve each other's bindings.
    expect(
      await bindings.findBinding(BindingKind.barcode, '0036000291452'),
      isNull,
    );

    await unmount(tester);
  });

  testWidgets('a barcode already bound to another target is refused, and says '
      'which target has it', (tester) async {
    await bindings.bind(
      targetId: car.id,
      kind: BindingKind.barcode,
      value: '5010358210016',
    );

    await pumpBarcode(tester);
    scan('5010358210016');
    await tester.pumpAndSettle();

    expect(find.textContaining('already bound to The car'), findsOneWidget);
    expect(find.byKey(const ValueKey('barcode-refused')), findsOneWidget);
    // Refused means refused: the car keeps its code.
    expect(
      (await bindings.findBinding(
        BindingKind.barcode,
        '5010358210016',
      ))?.targetId,
      car.id,
    );
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);
    expect(haptics, isEmpty);

    await unmount(tester);
  });

  testWidgets('the refusal survives the platform difference too — the same '
      'code in its other form is still claimed', (tester) async {
    // Bound off an Android phone, scanned here by an iPhone. Without the
    // canonicalisation this would look like a free code and quietly become a
    // second binding for the same box.
    await bindings.bind(
      targetId: car.id,
      kind: BindingKind.barcode,
      value: '036000291452',
    );

    await pumpBarcode(tester);
    scan('0036000291452');
    await tester.pumpAndSettle();

    expect(find.textContaining('already bound to The car'), findsOneWidget);
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);

    await unmount(tester);
  });

  testWidgets('binding the same code to the same target again is not a '
      'conflict', (tester) async {
    await bindings.bind(
      targetId: boiler.id,
      kind: BindingKind.barcode,
      value: '5010358210016',
    );

    await pumpBarcode(tester);
    scan('5010358210016');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('barcode-refused')), findsNothing);
    expect((await bindings.bindingsForTarget(boiler.id)).length, 1);

    await unmount(tester);
  });

  testWidgets('a nem label is not a product code and is turned away', (
    tester,
  ) async {
    await pumpBarcode(tester);
    scan(labelUriFor(car.id));
    await tester.pumpAndSettle();

    expect(find.textContaining('not a product code'), findsOneWidget);
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);

    await unmount(tester);
  });

  testWidgets('one visit binds one code', (tester) async {
    await pumpBarcode(tester);
    // A camera reports the same code several times a second, and a second
    // product in front of it after a successful bind is not a second binding.
    scan('5010358210016');
    await tester.pumpAndSettle();
    scan('4006381333931');
    await tester.pumpAndSettle();

    final bound = await bindings.bindingsForTarget(boiler.id);
    expect(bound.length, 1);
    expect(bound.single.value, '5010358210016');

    await unmount(tester);
  });
}
