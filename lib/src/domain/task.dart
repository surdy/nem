import 'due_status.dart';
import 'fixed_schedule.dart';
import 'schedule.dart';
import 'snooze.dart';

/// Which of the two schedule modes a task uses (ADR 0005).
enum ScheduleMode { floating, fixed }

/// A unit of recurring work with a schedule (CONTEXT.md — "Task").
///
/// Every task has exactly one schedule, and it is either floating or fixed. The
/// two are separate representations on the same record, held in mutually
/// exclusive fields, and deliberately not unified (ADR 0005).
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
    this.fixedSchedule,
    this.lastCompletedAt,
    this.reminderTime,
    this.snoozedUntil,
    this.snoozedAt,
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

  /// The stored form of a fixed schedule, set when [scheduleMode] is
  /// [ScheduleMode.fixed] (ADR 0006).
  ///
  /// Kept alongside [fixedSchedule] rather than replaced by it, so a rule this
  /// build cannot parse still round-trips and can still be shown as text
  /// instead of crashing the screen (ADR 0006).
  final String? rrule;

  /// [rrule] parsed, when it could be. Null for a floating task, and also for a
  /// fixed task whose stored rule did not parse.
  final FixedSchedule? fixedSchedule;

  final DateTime startDate;

  /// When this task was last performed.
  ///
  /// Derived from the completion log, not stored as truth (ADR 0004): it is
  /// `MAX(completed_at)` over the task's completions that have not been
  /// tombstoned, and null until the task has been completed once.
  final DateTime? lastCompletedAt;

  final String? reminderTime;

  /// The date this task was pushed out to, when it has been snoozed.
  ///
  /// Stored, authoritative, and deliberately NOT derived — see [SnoozeOption]
  /// for why a snooze cannot live in [dueDate].
  final DateTime? snoozedUntil;

  /// When the snooze in [snoozedUntil] was made.
  ///
  /// Kept so a later completion can supersede it without anything being
  /// deleted, which is what makes undo restore the snooze (ADR 0004).
  final DateTime? snoozedAt;

  /// Retired: kept, with its completion history, but off the due list.
  final bool isArchived;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The moment this task next needs doing (CONTEXT.md — "Due date").
  ///
  /// Derived on read from the schedule, the completion history and any snooze,
  /// never stored as truth (ADR 0004). The `tasks.due_date` column is only a
  /// sort key.
  ///
  /// A snooze is one of the inputs rather than an override written over the
  /// top: it is stored where recomputation cannot reach it and folded in here,
  /// so `recomputeDerivedState` reproduces this value instead of erasing it.
  /// See [SnoozeOption].
  DateTime? get dueDate => effectiveDueDate(
    scheduled: scheduledDueDate,
    snoozedUntil: snoozedUntil,
    snoozedAt: snoozedAt,
    lastCompletedAt: lastCompletedAt,
  );

  /// What the schedule alone says, before any snooze.
  ///
  /// The two modes compute it differently and cannot share a formula: floating
  /// measures forward from the last completion, fixed reads the calendar and
  /// pins to the earliest occurrence the last completion did not cover
  /// (ADR 0007). A fixed task's due date is therefore routinely in the past.
  DateTime? get scheduledDueDate {
    switch (scheduleMode) {
      case ScheduleMode.floating:
        final schedule = floatingSchedule;
        return schedule == null
            ? null
            : floatingDueDate(schedule, lastCompletedAt: lastCompletedAt);
      case ScheduleMode.fixed:
        final schedule = fixedSchedule;
        return schedule == null
            ? null
            : fixedDueDate(schedule, lastCompletedAt: lastCompletedAt);
    }
  }

  /// The schedule's human label, e.g. "Every 3 days" or "Every Tuesday".
  String? get scheduleLabel =>
      floatingSchedule?.label ?? fixedSchedule?.label ?? rrule;

  /// The task's urgency relative to [now].
  DueStatus? dueStatusAt(DateTime now) {
    final due = dueDate;
    return due == null ? null : dueStatusFor(due, now);
  }

  /// Whether a snooze is still holding this task off at [now] — what makes a
  /// snoozed task visibly distinct from one that is merely upcoming.
  bool isSnoozedAt(DateTime now) => snoozeHoldsAt(
    now: now,
    snoozedUntil: snoozedUntil,
    snoozedAt: snoozedAt,
    lastCompletedAt: lastCompletedAt,
    scheduled: scheduledDueDate,
  );
}
