import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/fixed_schedule.dart';
import 'package:nem/src/ui/fixed_schedule_editor.dart';
import 'package:timezone/data/latest.dart' as tz_data;

const london = 'Europe/London';

/// The editor mounted on its own, holding its draft the way a screen does.
///
/// No database and no providers: this widget is the authoring vocabulary and
/// nothing else, so it can be driven straight from a draft.
class _Harness extends StatefulWidget {
  const _Harness({this.draft, this.storedRule});

  final FixedScheduleDraft? draft;
  final String? storedRule;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late FixedScheduleDraft? _draft = widget.draft;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          child: FixedScheduleEditor(
            draft: _draft,
            storedRule: widget.storedRule,
            onChanged: (draft) => setState(() => _draft = draft),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(tz_data.initializeTimeZones);

  FixedScheduleDraft draft({
    FixedFrequency frequency = FixedFrequency.weekly,
    int interval = 1,
    Set<int> weekdays = const {DateTime.tuesday},
    MonthlyOn monthlyOn = MonthlyOn.dayOfMonth,
    FixedScheduleEnd end = const NeverEnds(),
    DateTime? startDate,
  }) => FixedScheduleDraft(
    frequency: frequency,
    interval: interval,
    weekdays: weekdays,
    monthlyOn: monthlyOn,
    end: end,
    startDate: startDate ?? DateTime(2026, 1, 20),
    zoneId: london,
  );

  Future<void> pump(
    WidgetTester tester, {
    FixedScheduleDraft? value,
    String? storedRule,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Harness(draft: value, storedRule: storedRule));
    await tester.pumpAndSettle();
  }

  String summary(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('schedule-summary'))).data!;

  group('the monthly shape', () {
    testWidgets('offers a day of the month and an nth weekday', (tester) async {
      // 20 January 2026 is the third Tuesday, and not in the last week.
      await pump(tester, value: draft(frequency: FixedFrequency.monthly));

      await tester.tap(find.byType(DropdownButtonFormField<MonthlyOn>));
      await tester.pumpAndSettle();
      expect(find.text('The 20th'), findsWidgets);
      expect(find.text('The third Tuesday'), findsWidgets);
      expect(find.text('The last Tuesday'), findsNothing);
    });

    testWidgets(
      'and the last weekday when the start date is in the last week',
      (tester) async {
        await pump(
          tester,
          value: draft(
            frequency: FixedFrequency.monthly,
            startDate: DateTime(2026, 1, 27),
          ),
        );

        await tester.tap(find.byType(DropdownButtonFormField<MonthlyOn>));
        await tester.pumpAndSettle();
        expect(find.text('The fourth Tuesday'), findsWidgets);
        expect(find.text('The last Tuesday'), findsWidgets);
      },
    );

    testWidgets('choosing one changes the summary and the rule', (
      tester,
    ) async {
      await pump(tester, value: draft(frequency: FixedFrequency.monthly));
      expect(summary(tester), 'Every month on the 20th');

      await tester.tap(find.byType(DropdownButtonFormField<MonthlyOn>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('The third Tuesday').last);
      await tester.pumpAndSettle();

      expect(summary(tester), 'Every month on the third Tuesday');
    });

    testWidgets('is offered for no other frequency', (tester) async {
      await pump(tester, value: draft());
      expect(find.byType(DropdownButtonFormField<MonthlyOn>), findsNothing);
      expect(
        find.byKey(const ValueKey('weekday-${DateTime.tuesday}')),
        findsOneWidget,
      );
    });

    testWidgets('says when a rule skips the short months', (tester) async {
      await pump(
        tester,
        value: draft(
          frequency: FixedFrequency.monthly,
          startDate: DateTime(2026, 1, 31),
        ),
      );
      expect(
        find.text('Months shorter than 31 days are skipped.'),
        findsOneWidget,
      );

      // And not when it is a weekday rule, which lands in every month.
      await tester.tap(find.byType(DropdownButtonFormField<MonthlyOn>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('The last Saturday').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Months shorter than 31 days are skipped.'),
        findsNothing,
      );
    });
  });

  group('the end condition', () {
    testWidgets('starts on never, and says nothing extra', (tester) async {
      await pump(tester, value: draft());
      expect(summary(tester), 'Every Tuesday');
      expect(find.byKey(const ValueKey('end-date')), findsNothing);
      expect(find.byKey(const ValueKey('end-count')), findsNothing);
    });

    testWidgets('a count is offered and read into the rule', (tester) async {
      await pump(tester, value: draft());

      await tester.tap(find.text('After'));
      await tester.pumpAndSettle();
      expect(summary(tester), 'Every Tuesday, for 10 occurrences');

      await tester.enterText(find.byKey(const ValueKey('end-count')), '3');
      await tester.pumpAndSettle();
      expect(summary(tester), 'Every Tuesday, for 3 occurrences');
    });

    testWidgets('a count below one is refused rather than stored', (
      tester,
    ) async {
      await pump(tester, value: draft());
      await tester.tap(find.text('After'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('end-count')), '0');
      await tester.pumpAndSettle();
      expect(
        Form.of(tester.element(find.byType(TextFormField))).validate(),
        isFalse,
      );
      await tester.pumpAndSettle();
      expect(find.text('At least 1'), findsOneWidget);
      // The rule itself is left on the last thing that made sense.
      expect(summary(tester), 'Every Tuesday, for 10 occurrences');
    });

    testWidgets('a date is offered, and defaults a year out', (tester) async {
      await pump(tester, value: draft());

      await tester.tap(find.text('On date'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('end-date')), findsOneWidget);
      expect(summary(tester), 'Every Tuesday, until 20 January 2027');
    });

    testWidgets('and can be picked', (tester) async {
      await pump(tester, value: draft());
      await tester.tap(find.text('On date'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('end-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('25'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(summary(tester), 'Every Tuesday, until 25 January 2027');
    });

    testWidgets('switching back to never drops it again', (tester) async {
      await pump(tester, value: draft(end: const EndsAfter(4)));
      expect(summary(tester), 'Every Tuesday, for 4 occurrences');

      await tester.tap(find.text('Never'));
      await tester.pumpAndSettle();
      expect(summary(tester), 'Every Tuesday');
      expect(find.byKey(const ValueKey('end-count')), findsNothing);
    });

    testWidgets('and coming back to it remembers what was there', (
      tester,
    ) async {
      await pump(tester, value: draft(end: const EndsAfter(4)));
      await tester.tap(find.text('Never'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('After'));
      await tester.pumpAndSettle();
      expect(summary(tester), 'Every Tuesday, for 4 occurrences');
    });
  });

  group('a rule the editor cannot represent (ADR 0006)', () {
    const imported =
        'DTSTART;TZID=Europe/London:20260301T000000\n'
        'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU';

    testWidgets('is shown as itself, read-only', (tester) async {
      await pump(tester, storedRule: imported);

      // Verbatim, including the DTSTART line — not re-rendered, not described.
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('uneditable-rule')),
            )
            .data,
        imported,
      );
      expect(find.textContaining('cannot edit this calendar rule'), findsOne);
    });

    testWidgets('and offers nothing that could overwrite it', (tester) async {
      await pump(tester, storedRule: imported);

      expect(find.byType(SegmentedButton<Object?>), findsNothing);
      expect(find.byType(DropdownButtonFormField<MonthlyOn>), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byKey(const ValueKey('schedule-summary')), findsNothing);
      expect(
        find.byKey(const ValueKey('weekday-${DateTime.tuesday}')),
        findsNothing,
      );
    });
  });
}
