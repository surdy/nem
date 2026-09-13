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
import 'package:nem/src/sync/sync_providers.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import '../notifications/fake_digest_notifier.dart';
import '../notifications/fake_reminder_notifier.dart';
import '../sync/fake_sync_channel.dart';
import '../sync/fake_sync_transport.dart';
import '../sync/task_rows.dart';

/// Realtime from the app's side (#13): what the due list does when the other
/// phone records a completion, and what happens to the subscription when nem
/// goes into the background.
///
/// Both seams are fakes. Nothing here opens a socket or reaches a network — see
/// `test/sync/fake_sync_channel.dart`.
void main() {
  const account = 'someone@example.com';

  late NemDatabase db;
  late TaskRepository tasks;
  late FakeSyncTransport transport;
  late FakeSyncChannel channel;

  // The task below is due on 1 July, so today is four days late.
  final today = DateTime(2026, 7, 5, 10);

  setUpAll(tz_data.initializeTimeZones);

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    tasks = TaskRepository(db);
    transport = FakeSyncTransport();
    channel = FakeSyncChannel();
  });

  tearDown(() => db.close());

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer. Disposing the scope also closes the realtime subscription.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          digestNotifierProvider.overrideWithValue(FakeDigestNotifier()),
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          clockProvider.overrideWithValue(() => today),
          // A configured, signed-in device. Both are the seams the suite
          // replaces; neither constructs a Supabase client.
          syncTransportProvider.overrideWithValue(transport),
          syncChannelProvider.overrideWithValue(channel),
          syncAccountProvider.overrideWith((ref) => Stream.value(account)),
        ],
        child: const NemApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Pumps until [finder] matches, or gives up.
  ///
  /// A sync is real asynchronous work against SQLite, so it does not finish
  /// inside a single `pumpAndSettle`: each pump both advances the coalescing
  /// timer and lets the pull's futures run.
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('gave up waiting for $finder');
  }

  /// nem goes into the background, the way both platforms walk the states.
  Future<void> background(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
  }

  /// And comes back.
  Future<void> resume(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
  }

  /// A floating task due on 1 July 2026.
  Future<String> createTask() async {
    final task = await tasks.createFloatingTask(
      title: 'Replace the water filter',
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: DateTime(2026, 6, 1, 9),
      now: DateTime(2026, 6, 1, 9),
    );
    return task.id;
  }

  /// The work done on the other phone, sitting on the backend.
  void recordCompletionOnTheOtherPhone(String taskId) => transport.seed(
    'completions',
    remoteCompletionJson(
      id: 'their-completion',
      taskId: taskId,
      completedAt: DateTime(2026, 7, 5, 9),
    ),
  );

  testWidgets('a completion recorded on the other phone moves the task off '
      'the overdue list without reopening the app', (tester) async {
    final id = await createTask();
    await pumpApp(tester);

    expect(find.text('OVERDUE'), findsOneWidget);
    expect(find.text('4 days late'), findsOneWidget);

    recordCompletionOnTheOtherPhone(id);
    channel.deliverChange();

    // The pull applies the completion and recomputes the derived due date
    // (ADR 0004), and the due list is a drift stream over that column, so it
    // regroups where it stands.
    await pumpUntil(tester, find.text('SOON'));
    expect(find.text('OVERDUE'), findsNothing);
    expect(find.text('4 days late'), findsNothing);

    await unmount(tester);
  });

  testWidgets('the subscription is torn down when nem goes into the '
      'background, and a new one is opened on resume', (tester) async {
    await createTask();
    await pumpApp(tester);

    expect(channel.isOpen, isTrue);
    expect(channel.opens, 1);

    await background(tester);

    expect(channel.isOpen, isFalse);
    expect(channel.closes, 1);

    await resume(tester);

    expect(channel.isOpen, isTrue);
    expect(channel.opens, 2);

    await unmount(tester);
  });

  testWidgets('work done while nem was backgrounded is on the due list when '
      'it comes back, though the socket never carried it', (tester) async {
    final id = await createTask();
    await pumpApp(tester);
    expect(find.text('OVERDUE'), findsOneWidget);

    await background(tester);
    recordCompletionOnTheOtherPhone(id);
    // Delivered to a subscription that is not there. This is the case realtime
    // cannot cover and is not asked to: the cursor is the record of what has
    // been applied, so the resume pulls it like any other missed row.
    channel.deliverChange();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('OVERDUE'), findsOneWidget);

    await resume(tester);
    await pumpUntil(tester, find.text('SOON'));

    expect(find.text('OVERDUE'), findsNothing);

    await unmount(tester);
  });
}
