import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/completion.dart';
import 'package:nem/src/domain/completion_history.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/domain/task.dart';

/// History is a pure function of the completion log (ADR 0004), so all of this
/// runs without a database: hand it completions, get back the gaps and the
/// window counts.
void main() {
  var nextId = 0;

  Completion completionAt(
    DateTime at, {
    CompletionSource source = CompletionSource.manual,
    String? note,
    DateTime? tombstonedAt,
  }) => Completion(
    id: 'completion-${nextId++}',
    taskId: 'task',
    completedAt: at,
    source: source,
    note: note,
    deviceId: 'device',
    createdAt: at,
    deletedAt: tombstonedAt,
  );

  Task every(int n, IntervalUnit unit, {DateTime? from, bool floating = true}) {
    final startDate = from ?? DateTime(2026, 1, 1, 9);
    return Task(
      id: 'task',
      title: 'Replace the water filter',
      scheduleMode: floating ? ScheduleMode.floating : ScheduleMode.fixed,
      floatingSchedule: floating
          ? FloatingSchedule(
              intervalN: n,
              intervalUnit: unit,
              startDate: startDate,
            )
          : null,
      startDate: startDate,
      createdAt: startDate,
      updatedAt: startDate,
    );
  }

  TaskHistory historyOf(
    Task task,
    List<Completion> completions, {
    DateTime? now,
  }) => historyFor(
    task: task,
    completions: completions,
    now: now ?? DateTime(2026, 6, 15, 12),
  );

  group('the log is read as it stands', () {
    test('a task with no completions has an empty history', () {
      final history = historyOf(every(7, IntervalUnit.day), []);
      expect(history.isEmpty, isTrue);
      expect(history.entries, isEmpty);
      expect(history.summaries.map((s) => s.completions), [0, 0]);
    });

    test('entries are newest work first', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 8, 9)),
        completionAt(DateTime(2026, 5, 25, 9)),
      ]);

      expect(history.entries.map((e) => e.completedAt), [
        DateTime(2026, 6, 8, 9),
        DateTime(2026, 6, 1, 9),
        DateTime(2026, 5, 25, 9),
      ]);
    });

    test('a completion carries its source through', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 8, 9), source: CompletionSource.tag),
      ]);
      expect(history.entries.single.source, CompletionSource.tag);
      expect(history.entries.single.source.displayLabel, 'By tag');
    });
  });

  group('the gap between consecutive completions', () {
    test('is null for the oldest completion, which has nothing behind it', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 8, 9)),
      ]);

      expect(history.entries.last.gapDays, isNull);
      expect(history.entries.last.gapLabel, isNull);
      expect(history.entries.first.gapDays, 7);
      expect(history.entries.first.gapLabel, '7 days later');
    });

    test(
      'makes a missed occurrence visible even though it was never a row',
      () {
        // ADR 0007: three missed weeks are still one row on the due list. The
        // 23-day gap is the only surviving trace that two of them went by.
        final history = historyOf(every(7, IntervalUnit.day), [
          completionAt(DateTime(2026, 6, 1, 9)),
          completionAt(DateTime(2026, 6, 24, 9)),
        ]);

        expect(history.entries.first.gapDays, 23);
        expect(history.entries.first.gapLabel, '23 days later');
      },
    );

    test('is measured in whole calendar days, not elapsed hours', () {
      // 22:00 to 08:00 is ten hours, but it is the next day.
      final history = historyOf(every(1, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 22)),
        completionAt(DateTime(2026, 6, 2, 8)),
      ]);

      expect(history.entries.first.gapDays, 1);
      expect(history.entries.first.gapLabel, '1 day later');
    });

    test('reads "Same day" when two completions land on one date', () {
      final history = historyOf(every(1, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 8)),
        completionAt(DateTime(2026, 6, 1, 20)),
      ]);

      expect(history.entries.first.gapDays, 0);
      expect(history.entries.first.gapLabel, 'Same day');
    });

    test('is computed after ordering, whatever order the log arrives in', () {
      // Completions merge from two devices in no particular order (ADR 0004).
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 24, 9)),
        completionAt(DateTime(2026, 6, 1, 9)),
      ]);

      expect(history.entries.first.gapDays, 23);
      expect(history.entries.last.gapDays, isNull);
    });
  });

  group('lateness against the schedule', () {
    test('the first completion is measured from the start date', () {
      // Start 1 January, every 7 days: due 8 January, done on the 11th.
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 1, 11, 9)),
      ]);

      expect(history.entries.single.scheduledFor, DateTime(2026, 1, 8, 9));
      expect(history.entries.single.daysLate, 3);
      expect(history.entries.single.lateLabel, '3 days late');
    });

    test('a 23-day gap on a 7-day schedule was 16 days late', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 24, 9)),
      ]);

      expect(history.entries.first.scheduledFor, DateTime(2026, 6, 8, 9));
      expect(history.entries.first.lateLabel, '16 days late');
    });

    test('work done on time carries no late label', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 8, 20)),
      ]);

      expect(history.entries.first.daysLate, 0);
      expect(history.entries.first.lateLabel, isNull);
    });

    test('work done early reads as negative, and shows no label', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 4, 9)),
      ]);

      expect(history.entries.first.daysLate, -4);
      expect(history.entries.first.lateLabel, isNull);
    });

    test('a monthly schedule is measured by calendar month', () {
      final history = historyOf(
        every(1, IntervalUnit.month, from: DateTime(2026, 1, 31, 9)),
        [completionAt(DateTime(2026, 2, 28, 9))],
      );

      // 31 January plus a month clamps to 28 February, so this was on time.
      expect(history.entries.single.scheduledFor, DateTime(2026, 2, 28, 9));
      expect(history.entries.single.lateLabel, isNull);
    });

    test('a schedule that yields no due date leaves lateness unknown', () {
      // Fixed schedules do not derive a due date yet; the gaps still work.
      final history = historyOf(every(7, IntervalUnit.day, floating: false), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 24, 9)),
      ]);

      expect(history.entries.first.scheduledFor, isNull);
      expect(history.entries.first.daysLate, isNull);
      expect(history.entries.first.lateLabel, isNull);
      expect(history.entries.first.gapDays, 23);
    });
  });

  group('tombstoned completions', () {
    test('never appear in the history', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(
          DateTime(2026, 6, 8, 9),
          tombstonedAt: DateTime(2026, 6, 8, 10),
        ),
      ]);

      expect(history.entries, hasLength(1));
      expect(history.entries.single.completedAt, DateTime(2026, 6, 1, 9));
    });

    test('a correction shows the replacement, never the row it retracted', () {
      // A correction is a tombstone plus a fresh row (ADR 0004) — "I did that
      // on the 3rd, not the 1st".
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(
          DateTime(2026, 6, 1, 9),
          tombstonedAt: DateTime(2026, 6, 3, 9),
        ),
        completionAt(DateTime(2026, 6, 3, 9)),
        completionAt(DateTime(2026, 6, 20, 9)),
      ]);

      expect(history.entries.map((e) => e.completedAt), [
        DateTime(2026, 6, 20, 9),
        DateTime(2026, 6, 3, 9),
      ]);
      // The gap is measured from the correction, not the retracted row: 17
      // days, not 19.
      expect(history.entries.first.gapDays, 17);
      expect(history.entries.last.gapDays, isNull);
    });

    test('do not count towards the window summaries', () {
      final now = DateTime(2026, 6, 15, 12);
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 8, 9), tombstonedAt: now),
      ], now: now);

      expect(history.summaries.first.completions, 1);
      expect(history.summaries.last.completions, 1);
    });
  });

  group('window summaries', () {
    final now = DateTime(2026, 6, 15, 12);

    test('are the last 30 and 90 days, in that order', () {
      final history = historyOf(every(7, IntervalUnit.day), [], now: now);
      expect(history.summaries.map((s) => s.windowDays), historyWindows);
      expect(history.summaries.map((s) => s.windowLabel), [
        'Last 30 days',
        'Last 90 days',
      ]);
    });

    test('count the completions inside each window', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 15, 8)), // today
        completionAt(DateTime(2026, 6, 1, 9)), // 14 days ago
        completionAt(DateTime(2026, 5, 20, 9)), // 26 days ago
        completionAt(DateTime(2026, 4, 20, 9)), // 56 days ago
        completionAt(DateTime(2026, 1, 20, 9)), // 146 days ago
      ], now: now);

      expect(history.summaries.first.completions, 3);
      expect(history.summaries.last.completions, 4);
    });

    test(
      'a window is inclusive of today and 29 days back, exclusive of 30',
      () {
        final thirtyDaysAgo = DateTime(2026, 5, 16, 9);
        final twentyNineDaysAgo = DateTime(2026, 5, 17, 9);

        expect(
          summariseWindow(
            [completionAt(twentyNineDaysAgo)],
            now: now,
            windowDays: 30,
          ).completions,
          1,
        );
        expect(
          summariseWindow(
            [completionAt(thirtyDaysAgo)],
            now: now,
            windowDays: 30,
          ).completions,
          0,
        );
      },
    );

    test('count labels read singular at one', () {
      expect(
        const HistorySummary(windowDays: 30, completions: 1).countLabel,
        '1 completion',
      );
      expect(
        const HistorySummary(windowDays: 30, completions: 0).countLabel,
        '0 completions',
      );
      expect(
        const HistorySummary(windowDays: 90, completions: 4).countLabel,
        '4 completions',
      );
    });
  });

  // These only bite when the test process runs in a timezone that observes
  // DST — CI runs the suite a second time under TZ=America/New_York for
  // exactly this reason. Under UTC they pass trivially.
  //
  // Every one of them fails if a day count is taken by differencing two local
  // instants and reading `.inDays`: a span containing the spring-forward is an
  // hour short and truncates down by one.
  group('daylight saving transitions', () {
    // US spring-forward 2026: Sunday 8 March, 02:00 -> 03:00.
    test('a gap spanning a spring-forward is not short by a day', () {
      final history = historyOf(every(1, IntervalUnit.day), [
        completionAt(DateTime(2026, 3, 7, 9)),
        completionAt(DateTime(2026, 3, 9, 9)),
      ], now: DateTime(2026, 3, 9, 12));

      expect(history.entries.first.gapDays, 2);
      expect(history.entries.first.gapLabel, '2 days later');
    });

    // US fall-back 2026: Sunday 1 November, 02:00 -> 01:00.
    test('a gap spanning an autumn fall-back is not long by a day', () {
      final history = historyOf(every(1, IntervalUnit.day), [
        completionAt(DateTime(2026, 10, 31, 9)),
        completionAt(DateTime(2026, 11, 2, 9)),
      ], now: DateTime(2026, 11, 2, 12));

      expect(history.entries.first.gapDays, 2);
    });

    test('the 30-day edge does not drift when the window spans a '
        'transition', () {
      final now = DateTime(2026, 3, 12, 9);
      // Exactly 30 calendar days back, so outside a 30-day window — but 29
      // days and 23 hours by the clock, which an hours-based window would let
      // in.
      final thirtyDaysAgo = DateTime(2026, 2, 10, 9);
      final twentyNineDaysAgo = DateTime(2026, 2, 11, 9);

      expect(
        summariseWindow(
          [completionAt(thirtyDaysAgo)],
          now: now,
          windowDays: 30,
        ).completions,
        0,
        reason: 'the 23-hour day must not pull a 30-day-old completion in',
      );
      expect(
        summariseWindow(
          [completionAt(twentyNineDaysAgo)],
          now: now,
          windowDays: 30,
        ).completions,
        1,
      );
    });

    test('the 90-day edge does not drift when the window spans a '
        'transition', () {
      final now = DateTime(2026, 3, 12, 9);
      final ninetyDaysAgo = DateTime(2025, 12, 12, 9);
      final eightyNineDaysAgo = DateTime(2025, 12, 13, 9);

      expect(
        summariseWindow(
          [completionAt(ninetyDaysAgo)],
          now: now,
          windowDays: 90,
        ).completions,
        0,
      );
      expect(
        summariseWindow(
          [completionAt(eightyNineDaysAgo)],
          now: now,
          windowDays: 90,
        ).completions,
        1,
      );
    });

    test('lateness across a transition counts whole days', () {
      // Due 7 March, done on the 9th: two days late, across the transition.
      final history = historyOf(
        every(7, IntervalUnit.day, from: DateTime(2026, 2, 28, 9)),
        [completionAt(DateTime(2026, 3, 9, 9))],
        now: DateTime(2026, 3, 9, 12),
      );

      expect(history.entries.single.scheduledFor, DateTime(2026, 3, 7, 9));
      expect(history.entries.single.lateLabel, '2 days late');
    });
  });

  group('future-dated completions', () {
    test('fall outside the trailing windows', () {
      final now = DateTime(2026, 6, 15, 12);
      expect(
        summariseWindow(
          [completionAt(DateTime(2026, 6, 16, 9))],
          now: now,
          windowDays: 30,
        ).completions,
        0,
      );
    });

    test('still appear in the history, newest first', () {
      final history = historyOf(every(7, IntervalUnit.day), [
        completionAt(DateTime(2026, 6, 1, 9)),
        completionAt(DateTime(2026, 6, 16, 9)),
      ], now: DateTime(2026, 6, 15, 12));

      expect(history.entries.first.completedAt, DateTime(2026, 6, 16, 9));
      expect(history.entries, hasLength(2));
    });
  });
}
