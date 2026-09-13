import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/ui/home_shell.dart';

void main() {
  late NemDatabase db;

  setUp(() => db = NemDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: HomeShell()),
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

  testWidgets('opens on the due list', (tester) async {
    await pumpShell(tester);
    expect(find.textContaining('Nothing due'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('targets are reachable from the navigation bar', (tester) async {
    await TargetRepository(db).createTarget(name: 'The boiler');

    await pumpShell(tester);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Targets'));
    await tester.pumpAndSettle();

    expect(find.text('The boiler'), findsOneWidget);
    await unmount(tester);
  });
}
