import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/digest.dart';

void main() {
  group('DigestTime', () {
    test('round-trips through its stored form', () {
      const time = DigestTime(hour: 8, minute: 5);
      expect(time.asHhMm, '08:05');
      expect(DigestTime.tryParse(time.asHhMm), time);
    });

    test('parses midnight and the last minute of the day', () {
      expect(
        DigestTime.tryParse('00:00'),
        const DigestTime(hour: 0, minute: 0),
      );
      expect(
        DigestTime.tryParse('23:59'),
        const DigestTime(hour: 23, minute: 59),
      );
    });

    test('rejects anything it cannot make sense of', () {
      for (final value in ['', '8', '8:00:00', 'ab:cd', '24:00', '08:60']) {
        expect(DigestTime.tryParse(value), isNull, reason: value);
      }
    });

    test('lands on the calendar day it is given, at its own time', () {
      const time = DigestTime(hour: 8, minute: 30);
      expect(
        time.onDayOf(DateTime(2026, 6, 15, 23, 59)),
        DateTime(2026, 6, 15, 8, 30),
      );
    });

    test('is built from a UTC instant in local time', () {
      // The digest is a wall-clock affair; an instant handed in from storage
      // must be read in the zone the user is standing in.
      const time = DigestTime(hour: 8, minute: 0);
      final utc = DateTime.utc(2026, 6, 15, 12);
      expect(time.onDayOf(utc).isUtc, isFalse);
      expect(time.onDayOf(utc), time.onDayOf(utc.toLocal()));
    });
  });

  group('DigestSettings', () {
    test('is off by default, at eight in the morning', () {
      expect(DigestSettings.defaults.isEnabled, isFalse);
      expect(
        DigestSettings.defaults.time,
        const DigestTime(hour: 8, minute: 0),
      );
    });

    test('copyWith changes one field at a time', () {
      final on = DigestSettings.defaults.copyWith(isEnabled: true);
      expect(on.isEnabled, isTrue);
      expect(on.time, DigestSettings.defaults.time);
    });
  });

  group('DigestCounts', () {
    test('says nothing when nothing is due', () {
      expect(DigestCounts.none.isEmpty, isTrue);
      expect(DigestCounts.none.total, 0);
    });

    test('reads both counts when there is some of each', () {
      const counts = DigestCounts(dueToday: 2, overdue: 3);
      expect(counts.title, 'Due today');
      expect(counts.body, '2 tasks due today, 3 overdue');
    });

    test('reads as overdue only when nothing is due today', () {
      const counts = DigestCounts(dueToday: 0, overdue: 4);
      expect(counts.title, 'Overdue');
      expect(counts.body, '4 tasks overdue');
    });

    test('is singular at one', () {
      expect(
        const DigestCounts(dueToday: 1, overdue: 0).body,
        '1 task due today',
      );
      expect(
        const DigestCounts(dueToday: 0, overdue: 1).body,
        '1 task overdue',
      );
    });
  });
}
