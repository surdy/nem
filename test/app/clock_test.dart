import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/app/clock.dart';
import 'package:nem/src/app/providers.dart';

void main() {
  group('day boundaries', () {
    test('the next boundary is the following local midnight', () {
      expect(
        nextDayBoundary(DateTime(2026, 6, 15, 23, 59, 59)),
        DateTime(2026, 6, 16),
      );
      expect(nextDayBoundary(DateTime(2026, 6, 15)), DateTime(2026, 6, 16));
      expect(
        untilNextDayBoundary(DateTime(2026, 6, 15, 23)),
        const Duration(hours: 1),
      );
    });

    test('month and year ends roll over', () {
      expect(nextDayBoundary(DateTime(2026, 1, 31, 12)), DateTime(2026, 2));
      expect(nextDayBoundary(DateTime(2026, 2, 28, 12)), DateTime(2026, 3));
      expect(nextDayBoundary(DateTime(2026, 12, 31, 12)), DateTime(2027));
      // 2028 is a leap year.
      expect(nextDayBoundary(DateTime(2028, 2, 28, 12)), DateTime(2028, 2, 29));
    });

    test('a UTC instant is measured against the local day it falls in', () {
      final instant = DateTime.utc(2026, 6, 15, 9);
      expect(startOfDay(instant), startOfDay(instant.toLocal()));
      expect(nextDayBoundary(instant), nextDayBoundary(instant.toLocal()));
    });

    test(
      'a daylight saving day is shorter or longer than 24 hours, and a fixed '
      '24 hours would miss its boundary',
      () {
        // Walks every day of a year in whatever zone the suite is running in,
        // which is the machine's own zone locally and America/New_York in the
        // second CI run. Nothing here names a zone: the transitions are found
        // by measuring, so the test has teeth wherever it runs and stays quiet
        // in UTC.
        final odd = <DateTime, Duration>{};
        for (
          var day = DateTime(2026);
          day.year == 2026;
          day = nextDayBoundary(day)
        ) {
          final span = untilNextDayBoundary(day);
          expect(
            span,
            greaterThan(Duration.zero),
            reason: 'the boundary after $day must be ahead of it',
          );
          if (span != const Duration(hours: 24)) odd[day] = span;
        }

        final shift =
            (DateTime(2026, 7).timeZoneOffset - DateTime(2026).timeZoneOffset)
                .abs();
        if (shift == Duration.zero) {
          expect(odd, isEmpty, reason: 'a zone without daylight saving');
          return;
        }

        // Spring forward and fall back: one short day and one long one.
        expect(odd, hasLength(2));
        expect(
          odd.values,
          everyElement(
            anyOf(
              const Duration(hours: 24) - shift,
              const Duration(hours: 24) + shift,
            ),
          ),
        );
        for (final transition in odd.keys) {
          expect(
            transition.add(const Duration(hours: 24)),
            isNot(nextDayBoundary(transition)),
            reason: 'adding a fixed day lands off the boundary on $transition',
          );
        }
      },
    );
  });

  group('the current day', () {
    // A ProviderContainer inside testWidgets, so the boundary timer is a fake
    // one that `pump` can advance by hours without the test taking hours. Each
    // test disposes its container, which cancels that timer.
    ProviderContainer containerAt(Clock clock) =>
        ProviderContainer(overrides: [clockProvider.overrideWithValue(clock)]);

    testWidgets('starts on the day the clock is in', (tester) async {
      final container = containerAt(() => DateTime(2026, 6, 15, 23));

      expect(container.read(currentDayProvider), DateTime(2026, 6, 15));
      expect(container.read(nowProvider), DateTime(2026, 6, 15, 23));

      container.dispose();
    });

    testWidgets('moves on its own when the boundary passes', (tester) async {
      var now = DateTime(2026, 6, 15, 23);
      final container = containerAt(() => now);
      expect(container.read(currentDayProvider), DateTime(2026, 6, 15));

      now = DateTime(2026, 6, 16, 0, 1);
      await tester.pump(const Duration(hours: 1, minutes: 1));

      expect(container.read(currentDayProvider), DateTime(2026, 6, 16));
      expect(container.read(nowProvider), now);

      container.dispose();
    });

    testWidgets('keeps moving, a day at a time, without a restart', (
      tester,
    ) async {
      var now = DateTime(2026, 6, 15, 23);
      final container = containerAt(() => now);

      for (var day = 16; day <= 19; day++) {
        now = DateTime(2026, 6, day, 0, 1);
        // One minute past the boundary the timer was armed for.
        await tester.pump(const Duration(hours: 1, minutes: 1));
        expect(container.read(currentDayProvider), DateTime(2026, 6, day));

        // The rest of the day, during which nothing should move.
        now = DateTime(2026, 6, day, 23);
        await tester.pump(const Duration(hours: 22, minutes: 59));
        expect(container.read(currentDayProvider), DateTime(2026, 6, day));
      }

      container.dispose();
    });

    testWidgets('a foreground after a day in the background catches up '
        'without the timer having fired', (tester) async {
      var now = DateTime(2026, 6, 15, 23);
      final container = containerAt(() => now);
      expect(container.read(currentDayProvider), DateTime(2026, 6, 15));

      // The process was suspended: no fake time elapses, so the boundary timer
      // never fires — but the world's clock has run on two days.
      now = DateTime(2026, 6, 17, 9);
      container.read(currentDayProvider.notifier).sync();

      expect(container.read(currentDayProvider), DateTime(2026, 6, 17));
      expect(container.read(nowProvider), now);

      container.dispose();
    });

    testWidgets('a foreground on the same day changes nothing', (tester) async {
      var now = DateTime(2026, 6, 15, 9);
      final container = containerAt(() => now);

      var rebuilds = 0;
      container.listen(currentDayProvider, (_, _) => rebuilds++);

      now = DateTime(2026, 6, 15, 17);
      container.read(currentDayProvider.notifier).sync();

      expect(rebuilds, 0);
      expect(container.read(currentDayProvider), DateTime(2026, 6, 15));

      container.dispose();
    });

    testWidgets('a pinned override still wins, and arms no timer', (
      tester,
    ) async {
      final pinned = DateTime(2026, 6, 15, 10);
      final container = ProviderContainer(
        overrides: [nowProvider.overrideWithValue(pinned)],
      );

      expect(container.read(nowProvider), pinned);
      // Nothing to fire: the timer lives behind the override, so a test that
      // pins the clock does not have to drain one.
      await tester.pump(const Duration(days: 2));
      expect(container.read(nowProvider), pinned);

      container.dispose();
    });
  });
}
