import 'package:nem/src/domain/digest_schedule.dart';
import 'package:nem/src/notifications/digest_notifier.dart';

/// A [DigestNotifier] that records what it was asked to do.
///
/// Everything the digest decides is decided before it reaches this seam, so a
/// fake here is enough to test the whole feature short of the platform call
/// itself — which no test can make, and no test pretends to.
class FakeDigestNotifier implements DigestNotifier {
  FakeDigestNotifier({
    this.permissionStatus = NotificationPermission.granted,
    this.permissionAfterRequest,
  });

  /// What the OS says now.
  NotificationPermission permissionStatus;

  /// What the OS says after being asked. Null means the request is granted.
  NotificationPermission? permissionAfterRequest;

  /// Notifications pending that the digest does not own — per-task reminders
  /// (issue #16) will look like this.
  final foreignPending = <int>[];

  /// Digest notifications currently pending, by id.
  final scheduled = <int, PlannedDigest>{};

  int initializeCount = 0;
  int requestCount = 0;
  int cancelCount = 0;

  @override
  Future<void> initialize() async => initializeCount++;

  @override
  Future<NotificationPermission> permission() async => permissionStatus;

  @override
  Future<NotificationPermission> requestPermission() async {
    requestCount++;
    permissionStatus = permissionAfterRequest ?? NotificationPermission.granted;
    return permissionStatus;
  }

  @override
  Future<List<int>> pendingIds() async => [
    ...foreignPending,
    ...scheduled.keys,
  ];

  @override
  Future<void> cancelDigests() async {
    cancelCount++;
    scheduled.clear();
  }

  @override
  Future<void> schedule(PlannedDigest digest) async {
    scheduled[digest.id] = digest;
  }
}
