import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/app.dart';
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
import 'package:timezone/data/latest.dart' as tz_data;

import '../nfc/fake_tag_launch_gateway.dart';
import '../notifications/fake_digest_notifier.dart';
import '../notifications/fake_reminder_notifier.dart';

/// Android tap-to-launch, from the URI inwards (#9).
///
/// The half of the gesture that can be tested at all. What cannot: the intent
/// filter matching, the dispatch itself, and the dedicated activity that
/// receives it — from Android 17 only the NFC system service may start that
/// activity, so no test and no `adb` command can (ADR 0009). Everything from
/// "a URI arrived" onwards is nem's own code and is exercised here, through the
/// app as it actually ships rather than through a harness.
void main() {
  late NemDatabase db;
  late TargetRepository targets;
  late TaskRepository tasks;
  late BindingRepository bindings;
  late Target boiler;
  late DateTime clock;
  late FakeTagLaunchGateway launches;

  setUpAll(tz_data.initializeTimeZones);

  setUp(() async {
    db = NemDatabase(NativeDatabase.memory());
    targets = TargetRepository(db);
    tasks = TaskRepository(db);
    bindings = BindingRepository(db);
    clock = DateTime(2026, 6, 15, 10);
    boiler = await targets.createTarget(name: 'The boiler');
    launches = FakeTagLaunchGateway();
    addTearDown(launches.dispose);
  });

  tearDown(() => db.close());

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// its query streams are cancelled, so the test does not end with a pending
  /// timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  /// Starts nem, exactly as `main` does bar the plugins.
  Future<void> launchNem(WidgetTester tester) async {
    // The haptic a completion buzzes with. Answered rather than left hanging,
    // because the completion is written after it.
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
          digestNotifierProvider.overrideWithValue(FakeDigestNotifier()),
          reminderNotifierProvider.overrideWithValue(FakeReminderNotifier()),
          clockProvider.overrideWithValue(() => clock),
          nowProvider.overrideWithValue(clock),
          tagLaunchGatewayProvider.overrideWithValue(launches),
        ],
        child: const NemApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The boiler wearing a tag. A launch is always NFC, so this is the binding
  /// kind a tapped URI has to match.
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

  testWidgets('a tag tapped with nem closed launches it and completes the '
      'work due there', (tester) async {
    await tagTheBoiler();
    await overdueTask('Bleed the radiators');
    // What the platform was holding when Dart started: the URI off the tag
    // that started the process.
    launches.launchUri = labelUriFor(boiler.id);

    await launchNem(tester);

    final completions = await completionsOf('Bleed the radiators');
    expect(completions.length, 1);
    // Sourced to the tag, because a launch can only have come off one — the
    // same URI on a printed label reaches the camera instead (ADR 0009).
    expect(completions.single.source, CompletionSource.tag);
    expect(
      find.text('Completed Bleed the radiators at The boiler'),
      findsOneWidget,
    );
    // And it landed on the due list rather than on a scan screen nobody asked
    // for.
    expect(find.text('Scan'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('the undo the launch offers takes the completion back', (
    tester,
  ) async {
    await tagTheBoiler();
    await overdueTask('Bleed the radiators');
    launches.launchUri = labelUriFor(boiler.id);

    await launchNem(tester);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(await completionsOf('Bleed the radiators'), isEmpty);
    await unmount(tester);
  });

  testWidgets('a tag tapped while nem is already open resolves without '
      'relaunching anything', (tester) async {
    await tagTheBoiler();
    await overdueTask('Bleed the radiators');

    await launchNem(tester);
    expect(await completionsOf('Bleed the radiators'), isEmpty);

    launches.tap(labelUriFor(boiler.id));
    await tester.pumpAndSettle();

    expect((await completionsOf('Bleed the radiators')).length, 1);
    expect(
      find.text('Completed Bleed the radiators at The boiler'),
      findsOneWidget,
    );
    // One home shell, not two: the tap resolved into the app that was already
    // running.
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('two tasks due at the tapped target are offered rather than '
      'guessed at', (tester) async {
    await tagTheBoiler();
    await overdueTask('Bleed the radiators');
    await overdueTask('Check the pressure');
    launches.launchUri = labelUriFor(boiler.id);

    await launchNem(tester);

    // The same sheet the scan screen shows, from the same code (ADR 0008).
    expect(find.text('Due at The boiler'), findsOneWidget);
    expect(await completionsOf('Bleed the radiators'), isEmpty);

    final bleed = (await tasks.allTasks()).firstWhere(
      (task) => task.title == 'Bleed the radiators',
    );
    await tester.tap(find.byKey(ValueKey('scan-task-${bleed.id}')));
    await tester.pumpAndSettle();
    expect((await completionsOf('Bleed the radiators')).length, 1);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('a tag nem does not know is offered for binding', (tester) async {
    // Nothing is bound to the boiler, so the tag that launched nem resolves to
    // nothing — and the one useful thing to do about it is offer to bind it.
    launches.launchUri = labelUriFor(boiler.id);

    await launchNem(tester);

    expect(find.textContaining('Unrecognised tag'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('bind-to-${boiler.id}')));
    await tester.pumpAndSettle();

    expect(
      (await bindings.findBinding(BindingKind.tag, boiler.id))?.targetId,
      boiler.id,
    );
    await unmount(tester);
  });

  /// A target with two tasks due at it, which is the shape that says out loud
  /// whether a tap resolved: an accepted scan puts the sheet on screen and a
  /// swallowed one does nothing at all, with no completion written either way
  /// to muddy the reading.
  Future<void> twoTasksDue() async {
    await tagTheBoiler();
    await overdueTask('Bleed the radiators');
    await overdueTask('Check the pressure');
  }

  testWidgets('a second tap within thirty seconds is swallowed', (
    tester,
  ) async {
    await twoTasksDue();
    launches.launchUri = labelUriFor(boiler.id);

    await launchNem(tester);
    expect(find.text('Due at The boiler'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    clock = clock.add(const Duration(seconds: 10));
    launches.tap(labelUriFor(boiler.id));
    await tester.pumpAndSettle();

    expect(find.text('Due at The boiler'), findsNothing);
    await unmount(tester);
  });

  testWidgets('the window holds across a cold launch, because the process '
      'does not', (tester) async {
    await twoTasksDue();
    launches.launchUri = labelUriFor(boiler.id);

    await launchNem(tester);
    expect(find.text('Due at The boiler'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Nem is killed. Everything the resolver held in memory goes with it — and
    // thirty seconds is long enough for Android to have done exactly that
    // between two taps on the same tag (#9).
    await unmount(tester);

    clock = clock.add(const Duration(seconds: 10));
    launches.launchUri = labelUriFor(boiler.id);
    await launchNem(tester);

    // Swallowed anyway. The window was read back off the same disk the
    // completion log is on, not out of a process that no longer exists.
    expect(find.text('Due at The boiler'), findsNothing);
    await unmount(tester);
  });

  testWidgets('and re-opens on the far side of it', (tester) async {
    await twoTasksDue();
    launches.launchUri = labelUriFor(boiler.id);

    await launchNem(tester);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await unmount(tester);

    // Past thirty seconds the same tag is a second visit rather than a fumble,
    // and a second visit is answered.
    clock = clock.add(const Duration(seconds: 31));
    launches.launchUri = labelUriFor(boiler.id);
    await launchNem(tester);

    expect(find.text('Due at The boiler'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('nem opened by hand resolves nothing at all', (tester) async {
    await tagTheBoiler();
    await overdueTask('Bleed the radiators');

    await launchNem(tester);

    expect(await completionsOf('Bleed the radiators'), isEmpty);
    expect(find.byType(SnackBar), findsNothing);

    await unmount(tester);
  });
}
