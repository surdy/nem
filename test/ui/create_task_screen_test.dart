import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/providers.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/target_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/task.dart';
import 'package:nem/src/ui/create_task_screen.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  late NemDatabase db;

  // A fixed schedule is anchored in a named zone (ADR 0010); pinning it keeps
  // the rule this form writes the same on every machine.
  setUpAll(tz_data.initializeTimeZones);
  setUp(() => db = NemDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pumpForm(WidgetTester tester) async {
    // A phone-shaped viewport puts the Create button below the fold once the
    // schedule mode selector is on the form. Give the test a tall window rather
    // than scrolling before every tap.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          zoneIdProvider.overrideWithValue('Europe/London'),
        ],
        child: const MaterialApp(home: CreateTaskScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Unmounts the tree and drains the zero-duration timer drift schedules when
  /// the target query stream is cancelled, so the test does not end with a
  /// pending timer.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  Future<void> chooseFixed(WidgetTester tester) async {
    await tester.tap(find.text('Fixed'));
    await tester.pumpAndSettle();
  }

  bool isWeekdaySelected(WidgetTester tester, int weekday) => tester
      .widget<FilterChip>(find.byKey(ValueKey('weekday-$weekday')))
      .selected;

  /// Taps whichever chips are in the wrong state, so the selection ends up
  /// exactly [weekdays] whatever weekday the test happens to run on.
  Future<void> selectWeekdays(WidgetTester tester, Set<int> weekdays) async {
    for (var weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++) {
      if (isWeekdaySelected(tester, weekday) != weekdays.contains(weekday)) {
        await tester.tap(find.byKey(ValueKey('weekday-$weekday')));
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('requires a title', (tester) async {
    await pumpForm(tester);
    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    expect(find.text('Give the task a title'), findsOneWidget);
    expect(await TaskRepository(db).allTasks(), isEmpty);
    await unmount(tester);
  });

  testWidgets('rejects an interval below 1', (tester) async {
    await pumpForm(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Bleed radiators');
    await tester.enterText(find.widgetWithText(TextFormField, '3'), '0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    expect(find.text('At least 1'), findsOneWidget);
    expect(await TaskRepository(db).allTasks(), isEmpty);
    await unmount(tester);
  });

  testWidgets('creates a floating task with title, notes and interval', (
    tester,
  ) async {
    await pumpForm(tester);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Replace the water filter');
    await tester.enterText(fields.at(1), 'Cartridge is under the sink');
    await tester.enterText(fields.at(2), '3');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    final task = (await TaskRepository(db).allTasks()).single;
    expect(task.title, 'Replace the water filter');
    expect(task.notes, 'Cartridge is under the sink');
    expect(task.floatingSchedule?.intervalN, 3);
    expect(task.floatingSchedule?.intervalUnit, IntervalUnit.day);
    expect(task.dueDate, task.startDate.add(const Duration(days: 3)));
    expect(task.targetId, isNull);
    await unmount(tester);
  });

  testWidgets('previews the derived first due date', (tester) async {
    await pumpForm(tester);
    expect(find.text('First due'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('offers no target field until a target exists', (tester) async {
    await pumpForm(tester);
    expect(find.text('Target (optional)'), findsNothing);
    await unmount(tester);
  });

  testWidgets('attaches the task to the chosen target', (tester) async {
    final target = await TargetRepository(db).createTarget(name: 'The boiler');

    await pumpForm(tester);
    await tester.enterText(
      find.byType(TextFormField).first,
      'Service the boiler',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('No target'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The boiler').last);
    await tester.pumpAndSettle();

    // The target field pushes the button past the bottom of a 600px test
    // viewport, and a ListView does not build what it cannot show.
    await tester.dragUntilVisible(
      find.text('Create task'),
      find.byType(ListView),
      const Offset(0, -100),
    );
    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    final task = (await TaskRepository(db).allTasks()).single;
    expect(task.title, 'Service the boiler');
    expect(task.targetId, target.id);
    await unmount(tester);
  });

  testWidgets('offers a weekday picker only for a weekly fixed schedule', (
    tester,
  ) async {
    await pumpForm(tester);
    expect(
      find.byKey(const ValueKey('weekday-${DateTime.tuesday}')),
      findsNothing,
    );

    await chooseFixed(tester);
    expect(
      find.byKey(const ValueKey('weekday-${DateTime.tuesday}')),
      findsOneWidget,
    );

    await tester.tap(find.byType(DropdownButtonFormField<FixedFrequency>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('months').last);
    await tester.pumpAndSettle();

    // Day-of-month and nth-weekday are issue #4, so a monthly rule has nothing
    // to pick here.
    expect(
      find.byKey(const ValueKey('weekday-${DateTime.tuesday}')),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets(
    'creates a fixed task from the frequency, interval and weekdays',
    (tester) async {
      await pumpForm(tester);
      await tester.enterText(
        find.byType(TextFormField).first,
        'Put the bins out',
      );
      await chooseFixed(tester);
      await tester.enterText(find.widgetWithText(TextFormField, '3'), '2');
      await tester.pumpAndSettle();
      await selectWeekdays(tester, {DateTime.tuesday, DateTime.friday});

      await tester.tap(find.text('Create task'));
      await tester.pumpAndSettle();

      final task = (await TaskRepository(db).allTasks()).single;
      expect(task.scheduleMode, ScheduleMode.fixed);
      expect(task.floatingSchedule, isNull);
      expect(task.rrule, contains('TZID=Europe/London'));
      expect(task.rrule, endsWith('RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,FR'));
      expect(task.fixedSchedule?.label, 'Every 2 weeks on Tuesday, Friday');
      expect(task.dueDate, isNotNull);
      await unmount(tester);
    },
  );

  testWidgets('a monthly fixed schedule repeats on the start date\'s day', (
    tester,
  ) async {
    await pumpForm(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Pay the rent');
    await chooseFixed(tester);
    await tester.tap(find.byType(DropdownButtonFormField<FixedFrequency>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('months').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '3'), '1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    final task = (await TaskRepository(db).allTasks()).single;
    expect(task.rrule, endsWith('RRULE:FREQ=MONTHLY'));
    expect(task.fixedSchedule?.label, 'Every month');
    expect(task.dueDate!.day, task.startDate.day);
    await unmount(tester);
  });

  testWidgets('previews the first due date of a fixed schedule too', (
    tester,
  ) async {
    await pumpForm(tester);
    await chooseFixed(tester);
    expect(find.text('First due'), findsOneWidget);
    await unmount(tester);
  });
}
