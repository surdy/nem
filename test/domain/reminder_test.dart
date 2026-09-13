import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/reminder.dart';

void main() {
  group('parsing what came out of tasks.reminder_time', () {
    test('reads a stored HH:mm', () {
      expect(ReminderTime.tryParse('19:00'), const ReminderTime(hour: 19));
      expect(
        ReminderTime.tryParse('07:45'),
        const ReminderTime(hour: 7, minute: 45),
      );
      expect(ReminderTime.tryParse('00:00'), const ReminderTime(hour: 0));
      expect(
        ReminderTime.tryParse('23:59'),
        const ReminderTime(hour: 23, minute: 59),
      );
    });

    test('an unpadded hour still reads, because storage is not the only '
        'writer', () {
      expect(
        ReminderTime.tryParse('7:05'),
        const ReminderTime(hour: 7, minute: 5),
      );
    });

    test('anything unreadable is no reminder rather than a crash', () {
      // This runs on the launch path. A row that cannot be read has to leave
      // the task without a reminder, not take the app down with it.
      for (final bad in [
        '',
        'off',
        '19',
        '19:00:00',
        '24:00',
        '19:60',
        'a:b',
      ]) {
        expect(ReminderTime.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('the storage form', () {
    test('pads both halves, so the column sorts and compares as text', () {
      expect(const ReminderTime(hour: 7, minute: 5).asHhMm, '07:05');
      expect(const ReminderTime(hour: 19).asHhMm, '19:00');
    });

    test('round-trips', () {
      const time = ReminderTime(hour: 6, minute: 30);
      expect(ReminderTime.tryParse(time.asHhMm), time);
    });
  });

  group('resolving to a day', () {
    test('lands at the wall-clock time on that calendar day', () {
      expect(
        const ReminderTime(hour: 19).onDayOf(DateTime(2026, 6, 15, 3, 12)),
        DateTime(2026, 6, 15, 19),
      );
    });

    test('a UTC instant is read as the local day it falls in', () {
      final resolved = const ReminderTime(
        hour: 19,
      ).onDayOf(DateTime.utc(2026, 6, 15, 12));
      final local = DateTime.utc(2026, 6, 15, 12).toLocal();
      expect(resolved, DateTime(local.year, local.month, local.day, 19));
      expect(resolved.isUtc, isFalse);
    });
  });

  test('ordering is by time of day', () {
    final times = [
      const ReminderTime(hour: 19),
      const ReminderTime(hour: 7, minute: 30),
      const ReminderTime(hour: 7, minute: 5),
    ]..sort();
    expect(times.map((t) => t.asHhMm), ['07:05', '07:30', '19:00']);
  });
}
