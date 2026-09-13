import 'barcode.dart';
import 'binding.dart';
import 'due_status.dart';
import 'target.dart';
import 'task.dart';

/// The hardware a scan came in through (CONTEXT.md — "Reader").
///
/// A different axis from the carrier, which is which of the three kinds of code
/// the value was read off. The reader narrows the carrier without deciding it:
/// the camera reads both labels and barcodes, and only what is in front of it
/// says which. [ScannedCode.kind] is where that derivation happens.
///
/// The reader is nevertheless the only thing that can settle a [BindingKind]
/// for a raw string: `nem://t/<uuid>` is identical on an NFC tag and on a
/// printed QR code, and only the hardware knows which one it came from. Keeping
/// it an argument rather than a guess is what lets #8 and #10 reuse
/// [ScanResolver] unchanged.
enum ScanReader {
  /// The camera. Its carrier is a [BindingKind.label] when the code carries a
  /// nem URI and a [BindingKind.barcode] when it carries anything else.
  camera,

  /// NFC hardware. Its carrier is always a [BindingKind.tag].
  nfc,
}

/// A raw scanned string, parsed against the reader it came in through.
///
/// Pure: parsing never touches the database, so "what kind of code is this and
/// what value would a binding store for it" is answerable without one.
class ScannedCode {
  const ScannedCode({
    required this.raw,
    required this.reader,
    required this.kind,
    required this.value,
    required this.isScanUri,
  });

  /// Parses [raw] as read through [reader].
  factory ScannedCode.parse(String raw, ScanReader reader) {
    final targetId = targetIdFromScanUri(raw);
    final kind = switch (reader) {
      // An NFC tag is a tag whatever it carries. A third-party tag with a
      // payload of its own is still bindable by that payload, which is #8's
      // problem and not a reason to call it something else here.
      ScanReader.nfc => BindingKind.tag,
      ScanReader.camera =>
        targetId == null ? BindingKind.barcode : BindingKind.label,
    };
    return ScannedCode(
      raw: raw,
      reader: reader,
      isScanUri: targetId != null,
      kind: kind,
      value: switch (kind) {
        // A product code is canonicalised, because the two platforms do not
        // report UPC-A the same way and a binding matches its value exactly
        // (see [normalisedBarcode]). A tag's own payload is not: nothing reads
        // it twice through two different frameworks.
        BindingKind.barcode => normalisedBarcode(raw),
        BindingKind.tag || BindingKind.label => targetId ?? raw.trim(),
      },
    );
  }

  /// Exactly what the reader handed over, before any trimming.
  final String raw;

  /// The hardware this code came in through.
  final ScanReader reader;

  /// The carrier: which of the three kinds of code this was read off
  /// (CONTEXT.md — "Carrier"), derived from the reader and from whether the
  /// value is one of nem's URIs. Also the kind a binding for it would have.
  final BindingKind kind;

  /// What a binding stores for this code: the uuid out of `nem://t/<uuid>`, or
  /// the code itself when it is not one of ours — canonicalised first if it is
  /// a product code ([normalisedBarcode]).
  final String value;

  /// Whether this code carries `nem://t/<uuid>` (ADR 0009), which is what makes
  /// [value] a target id rather than somebody else's product code.
  final bool isScanUri;

  @override
  String toString() => 'ScannedCode(${kind.name} $value)';
}

/// What a scan resolved to — the decision, not the act.
///
/// Nothing here completes anything, writes anything or vibrates. The resolver
/// returns one of these and the screen carries it out, which is what keeps the
/// camera, the haptics and the toast at the edges and this whole file
/// testable without a device.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// The code resolves to no live target: no binding for it, or a binding whose
/// target this device does not have.
///
/// Offer to bind it (PLAN.md — Resolution). A binding that names a target the
/// device cannot see is deliberately treated the same as no binding at all: a
/// dangling reference is an application-level unassignment rather than an error
/// (ADR 0011), and re-binding is the one action that helps.
final class ScanUnknownCode extends ScanOutcome {
  const ScanUnknownCode(this.code);

  final ScannedCode code;
}

/// The same target again, inside the repeat window — ignored so a fumbled scan
/// cannot double-log (PLAN.md — Resolution).
final class ScanRepeat extends ScanOutcome {
  const ScanRepeat({required this.target, required this.since});

  final Target target;

  /// How long ago the scan that this one repeats was accepted.
  final Duration since;
}

/// Exactly one task due at the target: complete it immediately, with a haptic,
/// a toast and a five-second undo.
final class ScanOneTaskDue extends ScanOutcome {
  const ScanOneTaskDue({
    required this.code,
    required this.target,
    required this.task,
  });

  final ScannedCode code;
  final Target target;
  final Task task;
}

/// Two or more tasks due at the target: present them and let each be ticked.
final class ScanSeveralTasksDue extends ScanOutcome {
  const ScanSeveralTasksDue({
    required this.code,
    required this.target,
    required this.tasks,
  });

  final ScannedCode code;
  final Target target;

  /// Soonest due first. Always two or more.
  final List<Task> tasks;
}

/// The target resolved and nothing is due there.
///
/// Show the target and its schedule and complete **nothing**. This is a
/// decision, not an omission (PLAN.md, "Settled without an ADR: no completion
/// when nothing is due"): scanning the boiler on a whim must not silently reset
/// a service interval that is three weeks off.
final class ScanNothingDue extends ScanOutcome {
  const ScanNothingDue({required this.code, required this.target});

  final ScannedCode code;
  final Target target;
}

/// What [ScanResolver] needs to look up, and nothing more.
///
/// Three questions, no streams and no writes. The data layer answers them from
/// drift; a test answers them from a map.
abstract interface class ScanLookup {
  /// The live binding for this kind and value, or null when there is none.
  Future<Binding?> findBinding(BindingKind kind, String value);

  /// The live target under [id], or null — including the "not synced yet" null
  /// that ADR 0011 makes legitimate.
  Future<Target?> findTarget(String id);

  /// Every live task at [targetId], due or not.
  Future<List<Task>> tasksForTarget(String targetId);
}

/// How long a second scan of the same target is ignored for (PLAN.md).
const scanRepeatWindow = Duration(seconds: 30);

/// Turns a scanned string into a decision.
///
/// This is the whole resolution flow, and it is deliberately the only part of
/// scanning that is not a widget: `scan → binding → target → tasks due → what
/// to do` (PLAN.md — Resolution). #8 passes it an NFC payload and #10 passes it
/// a product barcode; the only thing that differs is the [ScanReader].
///
/// It decides and does not act. Completing a task, buzzing the phone, showing a
/// sheet and offering undo all happen to an outcome, not inside this class.
///
/// The clock arrives as an argument rather than being read here, so the repeat
/// window can be exercised without waiting thirty seconds.
class ScanResolver {
  ScanResolver(this._lookup, {this.repeatWindow = scanRepeatWindow});

  final ScanLookup _lookup;

  /// How long after an accepted scan the same target is ignored for.
  final Duration repeatWindow;

  String? _lastTargetId;
  DateTime? _lastAcceptedAt;

  /// Resolves [raw], read through [reader], as at [now].
  Future<ScanOutcome> resolve(
    String raw, {
    ScanReader reader = ScanReader.camera,
    required DateTime now,
  }) async {
    final code = ScannedCode.parse(raw, reader);
    if (code.value.isEmpty) return ScanUnknownCode(code);

    final binding = await _lookup.findBinding(code.kind, code.value);
    if (binding == null) return ScanUnknownCode(code);

    final target = await _lookup.findTarget(binding.targetId);
    if (target == null) return ScanUnknownCode(code);

    final since = _sinceLastScanOf(target.id, now);
    if (since != null && since < repeatWindow) {
      return ScanRepeat(target: target, since: since);
    }

    // Only an accepted scan arms the window. Anchoring on the first scan rather
    // than sliding on every read is what makes the window usable at all: a
    // camera reports the same QR code several times a second, so a sliding
    // window pointed at one label would never re-open.
    _lastTargetId = target.id;
    _lastAcceptedAt = now;

    final due = tasksDueAt(await _lookup.tasksForTarget(target.id), now);
    return switch (due.length) {
      0 => ScanNothingDue(code: code, target: target),
      1 => ScanOneTaskDue(code: code, target: target, task: due.single),
      _ => ScanSeveralTasksDue(code: code, target: target, tasks: due),
    };
  }

  /// Forgets the repeat window, so the next scan of any target is accepted.
  ///
  /// The scan screen calls this when it opens: deliberately raising the camera
  /// again is a new intention, and it should not be swallowed because the same
  /// label was scanned twenty seconds ago.
  void reset() {
    _lastTargetId = null;
    _lastAcceptedAt = null;
  }

  /// How long ago [targetId] was last accepted, or null if it was not the last
  /// one.
  ///
  /// A [Duration] is right here and calendar arithmetic is not: this is elapsed
  /// time between two readings of the clock, thirty seconds apart, not a span
  /// of calendar days. Days go through `calendarDaysBetween`; seconds do not.
  Duration? _sinceLastScanOf(String targetId, DateTime now) {
    final at = _lastAcceptedAt;
    if (at == null || _lastTargetId != targetId) return null;
    final since = now.difference(at);
    // A clock that went backwards (a manual time change, a tz shift) must not
    // present as "scanned a moment ago" forever.
    return since.isNegative ? null : since;
  }
}

/// The tasks at a target that a scan can complete: due today or overdue,
/// soonest first.
///
/// Upcoming work is left out on purpose. A scan says "I am doing what needs
/// doing here", and a task that is not due yet does not need doing — completing
/// it would push its next due date out by a full interval for no reason
/// (PLAN.md — Resolution: "filtered to due or overdue").
List<Task> tasksDueAt(Iterable<Task> tasks, DateTime now) {
  final due = [
    for (final task in tasks)
      if (!task.isArchived && task.dueStatusAt(now) != DueStatus.upcoming)
        if (task.dueDate != null) task,
  ];
  due.sort((a, b) {
    final byDue = a.dueDate!.compareTo(b.dueDate!);
    return byDue != 0 ? byDue : a.title.compareTo(b.title);
  });
  return due;
}
