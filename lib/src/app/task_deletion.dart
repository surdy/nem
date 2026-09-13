import '../data/task_repository.dart';
import '../notifications/reminder_scheduler.dart';
import '../photos/photo_repository.dart';

/// Deleting a task, and everything that has to happen because of it.
///
/// The sibling of [TaskCompletions], and it exists for the same reason: a task
/// is not only a row. Deleting one has to take its reference photos with it
/// (issue #15) and has to take back any reminder still pending for it
/// (CONTEXT.md — "Reminder"), and neither is something a caller should have to
/// remember.
///
/// ## The order, which is the whole of this class
///
/// **Photos first, then the task.** Both halves are soft deletes and neither
/// can be atomic with the other — the photos' bytes are in Storage and in a
/// file, not in the transaction — so the question is only which way an
/// interruption should fall:
///
/// * Photos first, killed halfway: a live task with no photos. Visible,
///   describable, and the user can simply delete it again.
/// * Task first, killed halfway: a deleted task nothing shows, whose photos are
///   still rows in the database and still objects in the bucket, with nothing
///   left on screen that could ever go back and remove them. That is the leak
///   the ordering exists to prevent.
///
/// Within the photos half, the ordering is the opposite way round and for the
/// same kind of reason — the row's tombstone is pushed before the object is
/// removed from Storage, because bytes deleted there are gone for good while
/// the other device may not have seen the deletion yet. That argument lives on
/// `PhotoSync.drain`.
class TaskDeletion {
  const TaskDeletion({
    required this.tasks,
    required this.photos,
    required this.reminders,
  });

  final TaskRepository tasks;
  final PhotoRepository photos;
  final ReminderScheduler reminders;

  /// Deletes a task, its reference photos and its pending reminders.
  Future<void> delete(String taskId) async {
    await photos.deletePhotosForTask(taskId);
    await tasks.softDeleteTask(taskId);
    // A deleted task is not due, so nothing should fire for it. The whole
    // window is re-planned rather than one notification cancelled, because
    // which reminders should be pending is a fact about every task at once.
    await reminders.refresh();
  }
}
