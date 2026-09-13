import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/digest_settings_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/digest.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/notifications/digest_notifier.dart';
import 'package:nem/src/ui/settings_screen.dart';

import '../notifications/fake_digest_notifier.dart';

void main() {
  late NemDatabase db;
  late DigestSettingsRepository settings;
  late FakeDigestNotifier notifier;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    settings = DigestSettingsRepository(db);
    notifier = FakeDigestNotifier();
  });

  tearDown(() => db.close());

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(notifier),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addDueTask(WidgetTester tester) =>
      TaskRepository(db).createFloatingTask(
        title: 'Water the plants',
        intervalN: 1,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime.now(),
      );

  testWidgets('offers the digest, off, at its default time', (tester) async {
    await pumpSettings(tester);

    expect(find.text('Daily digest'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(find.text('8:00 AM'), findsOneWidget);
  });

  testWidgets('shows the stored time', (tester) async {
    await settings.write(
      const DigestSettings(
        isEnabled: true,
        time: DigestTime(hour: 19, minute: 30),
      ),
    );

    await pumpSettings(tester);

    expect(find.text('7:30 PM'), findsOneWidget);
  });

  testWidgets('switching the digest on stores it and schedules', (
    tester,
  ) async {
    await addDueTask(tester);
    await pumpSettings(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect((await settings.read()).isEnabled, isTrue);
    expect(notifier.scheduled, isNotEmpty);
  });

  testWidgets('asks for permission at the moment the digest is turned on', (
    tester,
  ) async {
    notifier.permissionStatus = NotificationPermission.notDetermined;
    await pumpSettings(tester);
    expect(notifier.requestCount, 0, reason: 'not on opening the screen');

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(notifier.requestCount, 1);
  });

  testWidgets('does not ask again when permission is already granted', (
    tester,
  ) async {
    notifier.permissionStatus = NotificationPermission.granted;
    await pumpSettings(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(notifier.requestCount, 0);
  });

  testWidgets('says so when permission is refused, and stays on', (
    tester,
  ) async {
    notifier
      ..permissionStatus = NotificationPermission.notDetermined
      ..permissionAfterRequest = NotificationPermission.denied;
    await pumpSettings(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(find.textContaining('Notifications are turned off'), findsOneWidget);
    expect((await settings.read()).isEnabled, isTrue);
  });

  testWidgets('no warning while notifications are allowed', (tester) async {
    await settings.write(
      const DigestSettings(
        isEnabled: true,
        time: DigestTime(hour: 8, minute: 0),
      ),
    );

    await pumpSettings(tester);

    expect(find.textContaining('Notifications are turned off'), findsNothing);
  });

  testWidgets('switching the digest off takes back what was pending', (
    tester,
  ) async {
    await addDueTask(tester);
    await settings.write(
      const DigestSettings(
        isEnabled: true,
        time: DigestTime(hour: 8, minute: 0),
      ),
    );
    await pumpSettings(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect((await settings.read()).isEnabled, isFalse);
    expect(notifier.scheduled, isEmpty);
    expect(notifier.cancelCount, greaterThan(0));
  });
}
