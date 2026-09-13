import 'due_status.dart';
import 'schedule.dart';

/// Which of the two schedule modes a task uses (ADR 0005).
enum ScheduleMode { floating, fixed }

/// A unit of recurring work with a schedule (CONTEXT.md — "Task").
///
/// Every task has exactly one schedule. Only floating schedules exist so far;
/// fixed schedules arrive with the RRULE editor.
class Task {
  const Task({
    required this.id,
    required this.title,
    required this.scheduleMode,
    required this.startDate,
    required this.createdAt,
    required this.updatedAt,
    this.notes,
    this.targetId,
    this.floatingSchedule,
    this.rrule,
    this.lastCompletedAt,
    this.reminderTime,
    this.isArchived = false,
  });

  final String id;
  final String title;
  final String? notes;

  /// The target this task is done on (ADR 0008), or null when the work is not
  /// attached to any one place or object.
  final String? targetId;

  final ScheduleMode scheduleMode;

  /// Set when [scheduleMode] is [ScheduleMode.floating].
  final FloatingSchedule? floatingSchedule;

  /// Set when [scheduleMode] is [ScheduleMode.fixed]. Unused so far.
  final String? rrule;

  final DateTime startDate;

  /// When this task was last performed.
  ///
  /// Derived from the completion log, not stored as truth (ADR 0004): it is
  /// `MAX(completed_at)` over the task's completions that have not been
  /// tombstoned, and null until the task has been completed once.
  final DateTime? lastCompletedAt;

  final String? reminderTime;
  final bool isArchived;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The moment this task next needs doing (CONTEXT.md — "Due date").
  ///
  /// Derived on read from the schedule and the completion history, never stored
  /// as truth (ADR 0004). The `tasks.due_date` column is only a sort key.
  DateTime? get dueDate {
    final schedule = floatingSchedule;
    if (scheduleMode == ScheduleMode.floating && schedule != null) {
      return floatingDueDate(schedule, lastCompletedAt: lastCompletedAt);
    }
    // Fixed schedules are not implemented yet.
    return null;
  }

  /// The task's urgency relative to [now].
  DueStatus? dueStatusAt(DateTime now) {
    final due = dueDate;
    return due == null ? null : dueStatusFor(due, now);
  }
}
