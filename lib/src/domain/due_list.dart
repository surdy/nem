import 'due_status.dart';
import 'task.dart';

/// One group of the due list — Overdue, Today or Soon.
class DueSection {
  const DueSection({required this.status, required this.tasks});

  final DueStatus status;
  final List<Task> tasks;

  String get heading => status.groupHeading;
  bool get isEmpty => tasks.isEmpty;
}

/// Groups tasks into Overdue / Today / Soon, each sorted by due date.
///
/// Sections are returned in urgency order and empty sections are dropped.
/// Tasks with no computable due date are omitted; only floating schedules exist
/// so far, and every floating schedule yields a due date.
List<DueSection> groupByDueStatus(Iterable<Task> tasks, DateTime now) {
  final buckets = <DueStatus, List<Task>>{
    DueStatus.overdue: [],
    DueStatus.dueToday: [],
    DueStatus.upcoming: [],
  };

  for (final task in tasks) {
    final due = task.dueDate;
    if (due == null) continue;
    buckets[dueStatusFor(due, now)]!.add(task);
  }

  for (final bucket in buckets.values) {
    bucket.sort((a, b) {
      final byDue = a.dueDate!.compareTo(b.dueDate!);
      return byDue != 0 ? byDue : a.title.compareTo(b.title);
    });
  }

  return [
    for (final status in DueStatus.values)
      if (buckets[status]!.isNotEmpty)
        DueSection(status: status, tasks: buckets[status]!),
  ];
}
