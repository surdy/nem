import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/binding.dart';
import 'package:nem/src/domain/completion.dart';
import 'package:nem/src/domain/interval_unit.dart';
import 'package:nem/src/domain/scan.dart';
import 'package:nem/src/domain/schedule.dart';
import 'package:nem/src/domain/target.dart';
import 'package:nem/src/domain/task.dart';

/// The resolution flow with nothing behind it: every branch of PLAN.md's table
/// is decided here, without a camera, a database or a phone.
class _FakeLookup implements ScanLookup {
  _FakeLookup({
    this.bindings = const [],
    this.targets = const [],
    this.tasks = const [],
  });

  List<Binding> bindings;
  List<Target> targets;
  List<Task> tasks;

  /// Every (kind, value) that was asked about, so the resolver's own choice of
  /// lookup key can be asserted.
  final asked = <String>[];

  @override
  Future<Binding?> findBinding(BindingKind kind, String value) async {
    asked.add('${kind.name}:$value');
    for (final binding in bindings) {
      if (binding.kind == kind && binding.value == value) return binding;
    }
    return null;
  }

  @override
  Future<Target?> findTarget(String id) async {
    for (final target in targets) {
      if (target.id == id) return target;
    }
    return null;
  }

  @override
  Future<List<Task>> tasksForTarget(String targetId) async =>
      tasks.where((task) => task.targetId == targetId).toList();
}

final _epoch = DateTime(2026, 6, 15, 10);

Target _target(String id, String name) =>
    Target(id: id, name: name, createdAt: _epoch, updatedAt: _epoch);

Binding _binding({
  required String targetId,
  required BindingKind kind,
  required String value,
}) => Binding(
  id: 'binding-$value-${kind.name}',
  targetId: targetId,
  kind: kind,
  value: value,
  createdAt: _epoch,
  updatedAt: _epoch,
);

/// A floating task at [targetId] due [dueInDays] from [_epoch] — negative for
/// overdue.
Task _task({
  required String id,
  required String title,
  String? targetId,
  int dueInDays = 0,
  bool isArchived = false,
}) {
  final start = addInterval(_epoch, dueInDays - 30, IntervalUnit.day);
  return Task(
    id: id,
    title: title,
    targetId: targetId,
    scheduleMode: ScheduleMode.floating,
    floatingSchedule: FloatingSchedule(
      intervalN: 30,
      intervalUnit: IntervalUnit.day,
      startDate: start,
    ),
    startDate: start,
    isArchived: isArchived,
    createdAt: _epoch,
    updatedAt: _epoch,
  );
}

void main() {
  group('the label URI', () {
    test('encodes a target as nem://t/<uuid>', () {
      expect(labelUriFor('abc-123'), 'nem://t/abc-123');
    });

    test('round-trips the target id back out', () {
      expect(targetIdFromScanUri(labelUriFor('abc-123')), 'abc-123');
    });

    test('ignores surrounding whitespace, which readers add', () {
      expect(targetIdFromScanUri('  nem://t/abc-123\n'), 'abc-123');
    });

    test('is not case sensitive in the scheme or the host', () {
      expect(targetIdFromScanUri('NEM://T/abc-123'), 'abc-123');
    });

    test('rejects everything that is not one of ours', () {
      // A product barcode, an https URL, our scheme pointing at something else,
      // and a target-less URI. All of these are somebody else's code.
      expect(targetIdFromScanUri('5010358210016'), isNull);
      expect(targetIdFromScanUri('https://example.com/t/abc'), isNull);
      expect(targetIdFromScanUri('nem://task/abc'), isNull);
      expect(targetIdFromScanUri('nem://t/'), isNull);
      expect(targetIdFromScanUri('nem://t/abc/def'), isNull);
      expect(targetIdFromScanUri(''), isNull);
    });
  });

  group('parsing a scanned code', () {
    test('a nem URI off the camera is a label', () {
      final code = ScannedCode.parse('nem://t/abc', ScanCarrier.camera);
      expect(code.kind, BindingKind.label);
      expect(code.value, 'abc');
      expect(code.isScanUri, isTrue);
    });

    test('anything else off the camera is a barcode, kept raw', () {
      final code = ScannedCode.parse(' 5010358210016 ', ScanCarrier.camera);
      expect(code.kind, BindingKind.barcode);
      expect(code.value, '5010358210016');
      expect(code.isScanUri, isFalse);
    });

    test('the same URI off NFC is a tag — only the carrier tells them '
        'apart', () {
      final code = ScannedCode.parse('nem://t/abc', ScanCarrier.nfc);
      expect(code.kind, BindingKind.tag);
      expect(code.value, 'abc');
    });

    test('each kind carries the completion source it records', () {
      expect(BindingKind.tag.completionSource, CompletionSource.tag);
      expect(BindingKind.label.completionSource, CompletionSource.label);
      expect(BindingKind.barcode.completionSource, CompletionSource.barcode);
    });
  });

  group('tasksDueAt', () {
    test('keeps overdue and due-today, drops upcoming', () {
      final tasks = [
        _task(id: 'a', title: 'Overdue', dueInDays: -3),
        _task(id: 'b', title: 'Today', dueInDays: 0),
        _task(id: 'c', title: 'Soon', dueInDays: 5),
      ];
      expect(tasksDueAt(tasks, _epoch).map((task) => task.id), ['a', 'b']);
    });

    test('drops archived work', () {
      final tasks = [
        _task(id: 'a', title: 'Overdue', dueInDays: -3, isArchived: true),
      ];
      expect(tasksDueAt(tasks, _epoch), isEmpty);
    });

    test('sorts soonest due first, then by title', () {
      final tasks = [
        _task(id: 'b', title: 'Bleed', dueInDays: 0),
        _task(id: 'a', title: 'Alarm', dueInDays: 0),
        _task(id: 'c', title: 'Clean', dueInDays: -9),
      ];
      expect(tasksDueAt(tasks, _epoch).map((task) => task.id), ['c', 'a', 'b']);
    });
  });

  group('resolving a scan', () {
    late _FakeLookup lookup;
    late ScanResolver resolver;
    final boiler = _target('target-1', 'The boiler');

    setUp(() {
      lookup = _FakeLookup(
        targets: [boiler],
        bindings: [
          _binding(
            targetId: boiler.id,
            kind: BindingKind.label,
            value: boiler.id,
          ),
        ],
      );
      resolver = ScanResolver(lookup);
    });

    test('exactly one task due completes immediately', () async {
      lookup.tasks = [
        _task(id: 'a', title: 'Bleed it', targetId: boiler.id, dueInDays: -2),
        _task(id: 'b', title: 'Service it', targetId: boiler.id, dueInDays: 40),
      ];

      final outcome = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch,
      );

      expect(outcome, isA<ScanOneTaskDue>());
      final one = outcome as ScanOneTaskDue;
      expect(one.task.id, 'a');
      expect(one.target.id, boiler.id);
      // Which is what makes the completion record source `label`.
      expect(one.code.kind.completionSource, CompletionSource.label);
    });

    test(
      'two or more due are handed over for disambiguation (ADR 0008)',
      () async {
        lookup.tasks = [
          _task(id: 'a', title: 'Bleed it', targetId: boiler.id, dueInDays: -2),
          _task(
            id: 'b',
            title: 'Service it',
            targetId: boiler.id,
            dueInDays: 0,
          ),
        ];

        final outcome = await resolver.resolve(
          labelUriFor(boiler.id),
          now: _epoch,
        );

        expect(outcome, isA<ScanSeveralTasksDue>());
        expect((outcome as ScanSeveralTasksDue).tasks.map((task) => task.id), [
          'a',
          'b',
        ]);
      },
    );

    test('nothing due resolves the target and completes nothing', () async {
      lookup.tasks = [
        _task(id: 'b', title: 'Service it', targetId: boiler.id, dueInDays: 40),
      ];

      final outcome = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch,
      );

      expect(outcome, isA<ScanNothingDue>());
      expect((outcome as ScanNothingDue).target.id, boiler.id);
    });

    test('a target with no tasks at all is still nothing due, not '
        'unknown', () async {
      final outcome = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch,
      );
      expect(outcome, isA<ScanNothingDue>());
    });

    test('a code with no binding is offered for binding', () async {
      final outcome = await resolver.resolve('5010358210016', now: _epoch);

      expect(outcome, isA<ScanUnknownCode>());
      final unknown = outcome as ScanUnknownCode;
      expect(unknown.code.kind, BindingKind.barcode);
      expect(unknown.code.value, '5010358210016');
    });

    test('a nem URI nobody bound is also unknown — resolution goes through '
        'the bindings table', () async {
      final outcome = await resolver.resolve(
        labelUriFor('some-other-target'),
        now: _epoch,
      );
      expect(outcome, isA<ScanUnknownCode>());
    });

    test('a binding whose target is missing is unknown rather than an '
        'error (ADR 0011)', () async {
      lookup.bindings = [
        _binding(
          targetId: 'not-synced-yet',
          kind: BindingKind.barcode,
          value: '5010358210016',
        ),
      ];

      final outcome = await resolver.resolve('5010358210016', now: _epoch);
      expect(outcome, isA<ScanUnknownCode>());
    });

    test('the binding is looked up under the carrier\'s kind', () async {
      await resolver.resolve(labelUriFor(boiler.id), now: _epoch);
      await resolver.resolve(
        labelUriFor(boiler.id),
        carrier: ScanCarrier.nfc,
        now: _epoch.add(const Duration(minutes: 1)),
      );

      // Same value, two kinds: a printed label and an NFC tag on the same
      // boiler are two bindings, and neither answers for the other.
      expect(lookup.asked, ['label:${boiler.id}', 'tag:${boiler.id}']);
    });
  });

  group('the repeat window', () {
    late _FakeLookup lookup;
    late ScanResolver resolver;
    final boiler = _target('target-1', 'The boiler');
    final door = _target('target-2', 'The front door');

    setUp(() {
      lookup = _FakeLookup(
        targets: [boiler, door],
        bindings: [
          _binding(
            targetId: boiler.id,
            kind: BindingKind.label,
            value: boiler.id,
          ),
          _binding(targetId: door.id, kind: BindingKind.label, value: door.id),
        ],
        tasks: [
          _task(
            id: 'a',
            title: 'Bleed it',
            targetId: 'target-1',
            dueInDays: -2,
          ),
          _task(id: 'b', title: 'Oil it', targetId: 'target-2', dueInDays: -2),
        ],
      );
      resolver = ScanResolver(lookup);
    });

    test('a second scan of the same target inside thirty seconds is '
        'ignored', () async {
      final first = await resolver.resolve(labelUriFor(boiler.id), now: _epoch);
      final second = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch.add(const Duration(seconds: 29)),
      );

      expect(first, isA<ScanOneTaskDue>());
      expect(second, isA<ScanRepeat>());
      expect((second as ScanRepeat).since, const Duration(seconds: 29));
    });

    test('the same target after the window resolves again', () async {
      await resolver.resolve(labelUriFor(boiler.id), now: _epoch);
      final later = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch.add(const Duration(seconds: 30)),
      );
      expect(later, isA<ScanOneTaskDue>());
    });

    test('the window is anchored on the accepted scan, not slid forward by '
        'the reads it swallows', () async {
      await resolver.resolve(labelUriFor(boiler.id), now: _epoch);
      // A camera reports the same code several times a second; a sliding
      // window would never re-open while the phone is held still.
      for (var second = 1; second < 30; second++) {
        await resolver.resolve(
          labelUriFor(boiler.id),
          now: _epoch.add(Duration(seconds: second)),
        );
      }
      final later = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch.add(const Duration(seconds: 31)),
      );
      expect(later, isA<ScanOneTaskDue>());
    });

    test('a different target inside the window is not a repeat', () async {
      await resolver.resolve(labelUriFor(boiler.id), now: _epoch);
      final other = await resolver.resolve(
        labelUriFor(door.id),
        now: _epoch.add(const Duration(seconds: 2)),
      );
      expect(other, isA<ScanOneTaskDue>());
      expect((other as ScanOneTaskDue).target.id, door.id);
    });

    test('an unknown code does not arm the window', () async {
      await resolver.resolve('5010358210016', now: _epoch);
      final known = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch.add(const Duration(seconds: 1)),
      );
      expect(known, isA<ScanOneTaskDue>());
    });

    test(
      'reset forgets it, so raising the camera again always scans',
      () async {
        await resolver.resolve(labelUriFor(boiler.id), now: _epoch);
        resolver.reset();
        final again = await resolver.resolve(
          labelUriFor(boiler.id),
          now: _epoch.add(const Duration(seconds: 1)),
        );
        expect(again, isA<ScanOneTaskDue>());
      },
    );

    test('a clock that jumps backwards does not freeze the window', () async {
      await resolver.resolve(labelUriFor(boiler.id), now: _epoch);
      final earlier = await resolver.resolve(
        labelUriFor(boiler.id),
        now: _epoch.subtract(const Duration(hours: 1)),
      );
      expect(earlier, isA<ScanOneTaskDue>());
    });

    test('the window is configurable, because #8 and #10 reuse this', () async {
      final short = ScanResolver(
        lookup,
        repeatWindow: const Duration(seconds: 5),
      );
      await short.resolve(labelUriFor(boiler.id), now: _epoch);
      expect(
        await short.resolve(
          labelUriFor(boiler.id),
          now: _epoch.add(const Duration(seconds: 6)),
        ),
        isA<ScanOneTaskDue>(),
      );
    });
  });
}
