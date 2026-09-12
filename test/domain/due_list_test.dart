import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/due_list.dart';
import 'package:nem/src/domain/due_status.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/domain/task.dart';

Task taskDue(String title, DateTime due) {
  // A 1-day floating schedule starting the day before [due] makes the derived
  // due date land exactly on [due].
  final start = DateTime(due.year, due.month, due.day - 1);
  return Task(
    id: title,
    title: title,
    scheduleMode: ScheduleMode.floating,
    floatingSchedule: FloatingSchedule(
      intervalN: 1,
      intervalUnit: IntervalUnit.day,
      startDate: start,
    ),
    startDate: start,
    createdAt: start,
    updatedAt: start,
  );
}

void main() {
  final now = DateTime(2026, 6, 15, 10, 0);

  test('a derived due date matches the helper construction', () {
    expect(taskDue('x', DateTime(2026, 6, 10)).dueDate, DateTime(2026, 6, 10));
  });

  test('groups into Overdue, Today and Soon in urgency order', () {
    final sections = groupByDueStatus([
      taskDue('soon', DateTime(2026, 6, 20)),
      taskDue('today', DateTime(2026, 6, 15)),
      taskDue('overdue', DateTime(2026, 6, 1)),
    ], now);

    expect(sections.map((s) => s.heading), ['Overdue', 'Today', 'Soon']);
    expect(sections.first.status, DueStatus.overdue);
  });

  test('sorts each group by due date', () {
    final sections = groupByDueStatus([
      taskDue('b', DateTime(2026, 6, 5)),
      taskDue('a', DateTime(2026, 6, 2)),
      taskDue('c', DateTime(2026, 6, 9)),
    ], now);

    expect(sections, hasLength(1));
    expect(sections.single.tasks.map((t) => t.title), ['a', 'b', 'c']);
  });

  test('drops empty groups', () {
    final sections = groupByDueStatus([
      taskDue('only', DateTime(2026, 6, 15)),
    ], now);
    expect(sections.map((s) => s.heading), ['Today']);
  });

  test('an empty task list produces no sections', () {
    expect(groupByDueStatus(const [], now), isEmpty);
  });

  test('a task with no computable due date is omitted', () {
    final fixed = Task(
      id: 'fixed',
      title: 'Rent',
      scheduleMode: ScheduleMode.fixed,
      rrule: 'FREQ=MONTHLY;BYMONTHDAY=1',
      startDate: DateTime(2026, 1, 1),
      createdAt: now,
      updatedAt: now,
    );
    expect(fixed.dueDate, isNull);
    expect(groupByDueStatus([fixed], now), isEmpty);
  });
}
