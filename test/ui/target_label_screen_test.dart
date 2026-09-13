import 'dart:io';

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
import 'package:nem/src/ui/target_label_screen.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

/// The channels the export path crosses: the share sheet itself, and the temp
/// directory share_plus copies the PNG into on its way there.
const _shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late NemDatabase db;
  late TargetRepository targets;
  late BindingRepository bindings;
  late Target boiler;

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    targets = TargetRepository(db);
    bindings = BindingRepository(db);
    boiler = await targets.createTarget(name: 'The boiler');
  });

  tearDown(() => db.close());

  Future<void> pumpLabel(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: TargetLabelScreen(target: boiler)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  testWidgets('shows the label and what it encodes', (tester) async {
    await pumpLabel(tester);

    expect(find.byKey(const ValueKey('label-qr')), findsOneWidget);
    expect(find.text('nem://t/${boiler.id}'), findsOneWidget);
    expect(find.text('The boiler'), findsOneWidget);

    // The QR really carries the URI, rather than the screen only printing it
    // underneath. `qrImage` is protected on the widget, and reading it is
    // exactly what a test is for.
    final view = tester.widget<PrettyQrView>(
      find.descendant(
        of: find.byKey(const ValueKey('label-qr')),
        matching: find.byType(PrettyQrView),
      ),
    );
    final expected = QrImage(
      QrCode.fromData(
        data: labelUriFor(boiler.id),
        errorCorrectLevel: QrErrorCorrectLevel.H,
      ),
    );
    // ignore: invalid_use_of_protected_member
    final rendered = view.qrImage;
    expect(rendered.moduleCount, expected.moduleCount);
    expect(
      [
        for (var row = 0; row < expected.moduleCount; row++)
          for (var col = 0; col < expected.moduleCount; col++)
            rendered.isDark(row, col),
      ],
      [
        for (var row = 0; row < expected.moduleCount; row++)
          for (var col = 0; col < expected.moduleCount; col++)
            expected.isDark(row, col),
      ],
    );

    await unmount(tester);
  });

  testWidgets('opening the label provisions the binding', (tester) async {
    expect(await bindings.bindingsForTarget(boiler.id), isEmpty);

    await pumpLabel(tester);

    final binding = (await bindings.bindingsForTarget(boiler.id)).single;
    expect(binding.kind, BindingKind.label);
    expect(binding.value, boiler.id);
    // Which is what makes the printed code resolve when it is scanned.
    expect(
      (await bindings.findBinding(BindingKind.label, boiler.id))?.id,
      binding.id,
    );

    await unmount(tester);
  });

  testWidgets('exporting hands a PNG of the label to the share sheet', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('nem-label-test');
    addTearDown(() => temp.deleteSync(recursive: true));

    Map<Object?, Object?>? shared;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return call.method == 'getTemporaryDirectory' ? temp.path : null;
    });
    messenger.setMockMethodCallHandler(_shareChannel, (call) async {
      if (call.method == 'share') {
        shared = call.arguments as Map<Object?, Object?>;
      }
      return 'com.example.target';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(_pathProviderChannel, null);
      messenger.setMockMethodCallHandler(_shareChannel, null);
    });

    await pumpLabel(tester);
    // Rendering the PNG is real engine work, so the tap that starts it has to
    // happen on the real clock rather than the fake one a widget test runs on.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('export-label')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();

    expect(shared, isNotNull);
    final paths = (shared!['paths']! as List<Object?>).cast<String>();
    expect(paths.single, endsWith('the-boiler-label.png'));

    final file = File(paths.single);
    expect(file.existsSync(), isTrue);
    // A real PNG, not an empty placeholder: the magic number, and enough bytes
    // to be a 1024px code.
    final bytes = file.readAsBytesSync();
    expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(bytes.length, greaterThan(1000));

    await unmount(tester);
  });
}
