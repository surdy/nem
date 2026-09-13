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
import 'package:timezone/data/latest.dart' as tz_data;

import '../notifications/fake_digest_notifier.dart';
import '../notifications/fake_reminder_notifier.dart';

void main() {
  late NemDatabase db;
  late TaskRepository repository;

  setUpAll(tz_data.initializeTimeZones);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = TaskRepository(db);
  });

  tearDown(() => db.close());

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer. Disposing the scope also cancels the day-boundary timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  /// Puts nem in the background and brings it back, the way Android and iOS
  /// walk the states. No fake time elapses, which is the point: a suspended
  /// process's timers do not fire, so anything that catches up here has done it
  /// on the lifecycle event alone.
  Future<void> backgroundAndResume(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a resume across a day boundary regroups the due list', (
    tester,
  ) async {
    // Due 15 June: today, when the app goes into the background.
    await repository.createFloatingTask(
      title: 'Water the plants',
      intervalN: 14,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    var clock = DateTime(2026, 6, 15, 22);
    final notifier = FakeDigestNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(notifier),
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          clockProvider.overrideWithValue(() => clock),
        ],
        child: const NemApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);

    // Away for two days.
    clock = DateTime(2026, 6, 17, 9);
    await backgroundAndResume(tester);

    expect(find.text('OVERDUE'), findsOneWidget);
    expect(find.text('TODAY'), findsNothing);
    expect(find.text('2 days late'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a resume within the same day leaves the grouping alone', (
    tester,
  ) async {
    await repository.createFloatingTask(
      title: 'Water the plants',
      intervalN: 14,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1),
    );

    var clock = DateTime(2026, 6, 15, 9);
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

    clock = DateTime(2026, 6, 15, 17);
    await backgroundAndResume(tester);

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the digest is still re-topped on resume', (tester) async {
    final notifier = FakeDigestNotifier();
    var clock = DateTime(2026, 6, 15, 9);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(notifier),
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          clockProvider.overrideWithValue(() => clock),
        ],
        child: const NemApp(),
      ),
    );
    await tester.pumpAndSettle();

    final before = notifier.cancelCount;
    clock = DateTime(2026, 6, 16, 9);
    await backgroundAndResume(tester);

    // The day catch-up shares the listener with the digest refresh; neither
    // has displaced the other.
    expect(notifier.cancelCount, greaterThan(before));

    await unmount(tester);
  });
}
