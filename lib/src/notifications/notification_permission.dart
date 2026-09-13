/// Whether the OS will let nem post notifications.
///
/// A fact about the platform rather than about either feature, so the digest
/// and per-task reminders both read it. It lives in its own file — and is
/// re-exported from `digest_notifier.dart`, where it used to be declared — so
/// that reminders do not have to import the digest to ask a question that has
/// nothing to do with the digest.
enum NotificationPermission {
  /// Never asked. On iOS this is the state in which asking still shows the
  /// system prompt; once it is [denied] the prompt never appears again.
  notDetermined,

  granted,

  /// Refused, or switched off later in the system settings. Notifications are
  /// still scheduled — nothing throws — they simply never appear.
  denied;

  bool get isGranted => this == NotificationPermission.granted;
}
