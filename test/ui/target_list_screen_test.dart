import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/ui/target_detail_screen.dart';
import 'package:nem/src/ui/target_form_screen.dart';
import 'package:nem/src/ui/target_list_screen.dart';

void main() {
  late NemDatabase db;
  late TargetRepository repository;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TargetRepository(db);
  });

  tearDown(() => db.close());

  Future<void> pumpTargets(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: TargetListScreen()),
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

  testWidgets('explains what a target is when there are none', (tester) async {
    await pumpTargets(tester);
    expect(find.textContaining('No targets yet'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('lists targets with their descriptions', (tester) async {
    await repository.createTarget(
      name: 'The boiler',
      description: 'In the airing cupboard',
    );
    await repository.createTarget(name: 'The car');

    await pumpTargets(tester);

    expect(find.text('The boiler'), findsOneWidget);
    expect(find.text('In the airing cupboard'), findsOneWidget);
    expect(find.text('The car'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('opens a target', (tester) async {
    await repository.createTarget(name: 'The boiler');

    await pumpTargets(tester);
    await tester.tap(find.text('The boiler'));
    await tester.pumpAndSettle();

    expect(find.byType(TargetDetailScreen), findsOneWidget);
    expect(find.text('TASKS'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('creates a target from the form', (tester) async {
    await pumpTargets(tester);
    await tester.tap(find.text('New target'));
    await tester.pumpAndSettle();

    expect(find.byType(TargetFormScreen), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'The front door');
    await tester.enterText(fields.at(1), 'Hinges and the lock');
    await tester.tap(find.text('Create target'));
    await tester.pumpAndSettle();

    final target = (await repository.allTargets()).single;
    expect(target.name, 'The front door');
    expect(target.description, 'Hinges and the lock');
    expect(find.text('The front door'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('requires a name', (tester) async {
    await pumpTargets(tester);
    await tester.tap(find.text('New target'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create target'));
    await tester.pumpAndSettle();

    expect(find.text('Give the target a name'), findsOneWidget);
    expect(await repository.allTargets(), isEmpty);
    await unmount(tester);
  });

  testWidgets('renames a target from its detail screen', (tester) async {
    final target = await repository.createTarget(name: 'Boiler');

    await pumpTargets(tester);
    await tester.tap(find.text('Boiler'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'The boiler');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect((await repository.findTarget(target.id))?.name, 'The boiler');
    // The detail screen's title follows the rename, because it watches the row.
    expect(find.text('The boiler'), findsOneWidget);
    await unmount(tester);
  });
}
