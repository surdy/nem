import 'completion.dart';
import 'due_status.dart';
import 'schedule.dart';
import 'task.dart';

/// One line of a task's history: a completion, and how it sat against the work
/// before it.
///
/// Built from the completion log and nothing else (ADR 0004). `tasks.due_date`
/// and `tasks.last_completed_at` are sort caches, so a history built on them
/// would agree with a stale cache rather than expose it.
class HistoryEntry {
  const HistoryEntry({
    required this.completion,
    this.gapDays,
    this.scheduledFor,
  });

  final Completion completion;

  /// Whole calendar days since the previous completion, or null for the oldest
  /// one, which has nothing behind it.
  ///
  /// This is the number that makes missed occurrences visible. ADR 0007 keeps
  /// them off the due list on purpose — a task is one row however many
  /// occurrences it has missed — so the gaps in the log are the only place they
  /// survive. A task scheduled every 7 days with a 23-day gap missed two.
  final int? gapDays;

  /// The due date this completion was measured against: the due date the task
  /// carried in the moment before it was completed.
  ///
  /// Recomputed here rather than read back from the task, because
  /// `tasks.due_date` only ever holds the *current* due date — every past one
  /// has to come from the schedule and the completion before it. Null when the
  /// task's schedule cannot produce one, which is every fixed schedule so far.
  final DateTime? scheduledFor;

  DateTime get completedAt => completion.completedAt;
  CompletionSource get source => completion.source;

  /// How many calendar days late the work was, negative when it was early.
  /// Null when there is no due date to measure it against.
  int? get daysLate {
    final due = scheduledFor;
    return due == null ? null : calendarDaysBetween(due, completedAt);
  }

  /// "23 days late", or null when the work was done on or before its due date.
  String? get lateLabel {
    final due = scheduledFor;
    return due == null ? null : overdueLabel(due, completedAt);
  }

  /// "23 days later", or null for the oldest completion.
  String? get gapLabel => switch (gapDays) {
    null => null,
    0 => 'Same day',
    1 => '1 day later',
    final gap => '$gap days later',
  };
}

/// How many completions landed inside one trailing window of calendar days.
class HistorySummary {
  const HistorySummary({required this.windowDays, required this.completions});

  final int windowDays;
  final int completions;

  String get windowLabel => 'Last $windowDays days';

  String get countLabel =>
      completions == 1 ? '1 completion' : '$completions completions';
}

/// The trailing windows a task's history is summarised over.
const historyWindows = [30, 90];

/// A task's completion history: every surviving completion, newest work first,
/// plus the trailing-window counts.
class TaskHistory {
  const TaskHistory({required this.entries, required this.summaries});

  static const empty = TaskHistory(entries: [], summaries: []);

  /// Newest work first, matching the order the log is read in.
  final List<HistoryEntry> entries;

  final List<HistorySummary> summaries;

  bool get isEmpty => entries.isEmpty;
  int get completionCount => entries.length;
}

/// Builds [task]'s history from its completion log.
///
/// [completions] may arrive in any order, and tombstoned rows are dropped here
/// as well as by the query that fetched them: a history says what happened, and
/// a tombstoned completion is one that was taken back or superseded by a
/// correction (ADR 0004).
TaskHistory historyFor({
  required Task task,
  required Iterable<Completion> completions,
  required DateTime now,
}) {
  final live = [
    for (final completion in completions)
      if (!completion.isTombstoned) completion,
  ]..sort((a, b) => a.completedAt.compareTo(b.completedAt));

  final schedule = task.floatingSchedule;
  final entries = <HistoryEntry>[];
  DateTime? previous;
  for (final completion in live) {
    entries.add(
      HistoryEntry(
        completion: completion,
        gapDays: previous == null
            ? null
            : calendarDaysBetween(previous, completion.completedAt),
        // The due date in force before this completion: measured forward from
        // the completion before it, or from the start date when there was none.
        scheduledFor: schedule == null
            ? null
            : floatingDueDate(schedule, lastCompletedAt: previous),
      ),
    );
    previous = completion.completedAt;
  }

  return TaskHistory(
    entries: entries.reversed.toList(),
    summaries: [
      for (final windowDays in historyWindows)
        summariseWindow(live, now: now, windowDays: windowDays),
    ],
  );
}

/// Counts the completions falling in the [windowDays] calendar days ending
/// today — today itself plus the [windowDays] - 1 days before it.
///
/// Counted in whole calendar days rather than elapsed hours, for the reason
/// spelled out on [calendarDaysBetween]: a 30-day span whose far edge sits on
/// the other side of a daylight saving transition is an hour short or an hour
/// long, so an hours-based window would take a completion in or out at the
/// boundary depending on the time of year.
HistorySummary summariseWindow(
  Iterable<Completion> completions, {
  required DateTime now,
  required int windowDays,
}) {
  var count = 0;
  for (final completion in completions) {
    if (completion.isTombstoned) continue;
    final daysAgo = calendarDaysBetween(completion.completedAt, now);
    if (daysAgo >= 0 && daysAgo < windowDays) count++;
  }
  return HistorySummary(windowDays: windowDays, completions: count);
}
