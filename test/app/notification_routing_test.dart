import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/app.dart';
import 'package:nem/src/app/clock.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/notifications/local_digest_notifier.dart';
import 'package:nem/src/notifications/local_reminder_notifier.dart';
import 'package:nem/src/ui/due_list_screen.dart';
import 'package:nem/src/ui/settings_screen.dart';
import 'package:nem/src/ui/task_detail_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import '../notifications/fake_digest_notifier.dart';
import '../notifications/fake_reminder_notifier.dart';

void main() {
  late NemDatabase db;
  late TaskRepository repository;
  final clock = DateTime(2026, 6, 15, 10);

  setUpAll(tz_data.initializeTimeZones);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  Future<String> addTask() async {
    final task = await repository.createFloatingTask(
      title: 'Put the bins out',
      intervalN: 7,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );
    return task.id;
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(FakeDigestNotifier()),
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          clockProvider.overrideWithValue(() => clock),
        ],
        child: const NemApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('what a payload names', () {
    test('a reminder carries its task', () {
      expect(reminderTaskId(reminderPayload('abc-123')), 'abc-123');
    });

    test('a digest names no task, so it routes to the due list', () {
      expect(reminderTaskId(digestPayload), isNull);
    });

    test('a payload from nowhere is not a reminder', () {
      // A tap handler runs inside a platform callback; a payload written by an
      // older build can still be sitting in the OS queue when a newer one
      // reads it. None of these may throw.
      for (final payload in [null, '', 'reminder:', 'something else']) {
        expect(reminderTaskId(payload), isNull, reason: '$payload');
      }
    });
  });

  group('where a tap lands', () {
    testWidgets('a reminder opens the task it is about', (tester) async {
      final taskId = await addTask();
      await pumpApp(tester);
      expect(find.byType(TaskDetailScreen), findsNothing);

      showNotificationTarget(reminderPayload(taskId));
      await tester.pumpAndSettle();

      expect(find.byType(TaskDetailScreen), findsOneWidget);
      expect(find.text('Put the bins out'), findsWidgets);
      await unmount(tester);
    });

    testWidgets('a digest opens the due list', (tester) async {
      await addTask();
      await pumpApp(tester);

      // Somewhere else in the app, as it would be if nem were backgrounded
      // with the settings open.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      showNotificationTarget(digestPayload);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byType(DueListScreen), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('two reminders in a row leave one task screen, not a pile', (
      tester,
    ) async {
      final first = await addTask();
      final second = (await repository.createFloatingTask(
        title: 'Water the plants',
        intervalN: 3,
        intervalUnit: IntervalUnit.day,
        startDate: DateTime(2026, 6, 1),
      )).id;
      await pumpApp(tester);

      showNotificationTarget(reminderPayload(first));
      await tester.pumpAndSettle();
      showNotificationTarget(reminderPayload(second));
      await tester.pumpAndSettle();

      expect(find.byType(TaskDetailScreen), findsOneWidget);
      // Back goes to the due list, not to the other task.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailScreen), findsNothing);
      expect(find.byType(DueListScreen), findsOneWidget);
      await unmount(tester);
    });
  });
}
