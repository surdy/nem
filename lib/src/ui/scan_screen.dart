import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/clock.dart';
import '../app/providers.dart';
import '../domain/completion.dart';
import '../domain/scan.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import 'due_list_screen.dart' show formatDueDate;
import 'target_detail_screen.dart';

/// Builds the live view scans arrive from, calling back with each raw value.
///
/// Injected so the flow above it can be exercised without a camera: the real
/// builder is a [MobileScanner] preview, and a test supplies something that
/// emits a string on demand. Everything below this typedef — resolution,
/// completion, undo — is the same code either way.
typedef ScanPreviewBuilder =
    Widget Function(BuildContext context, ValueChanged<String> onScanned);

/// How long the undo affordance stays on screen after a scan completes
/// something. The same five seconds the due list offers.
const scanUndoWindow = Duration(seconds: 5);

/// The camera scan screen: point at a label, and the work due there gets done.
///
/// The screen is the edge of the scan flow and nothing more. It owns the
/// camera, the haptic and the toast; what a scanned string *means* is
/// [ScanResolver]'s answer, and this widget only carries out the outcome it is
/// handed (PLAN.md — Resolution).
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, this.previewBuilder});

  /// Overrides the camera preview. Tests only.
  @visibleForTesting
  final ScanPreviewBuilder? previewBuilder;

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  MobileScannerController? _controller;

  /// Set while an outcome is being carried out, so the camera's stream of
  /// detections cannot stack two sheets or complete something twice while the
  /// first scan is still being dealt with.
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    if (widget.previewBuilder == null) {
      // Formats are left open rather than restricted to QR: a product barcode
      // in front of the camera is a code nem can offer to bind (#10), and
      // refusing to read it here would be a different screen's problem later.
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
      );
    }
    // Raising the camera is a fresh intention: the thirty-second repeat window
    // exists to swallow a fumbled second read, not to swallow a deliberate
    // second visit.
    ref.read(scanResolverProvider).reset();
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  Future<void> _onScanned(String raw) async {
    if (_handling) return;
    _handling = true;
    try {
      final outcome = await ref
          .read(scanResolverProvider)
          .resolve(raw, now: ref.read(clockProvider)());
      if (!mounted) return;
      await _present(outcome);
    } finally {
      _handling = false;
    }
  }

  /// Carries out a decision. Every branch of PLAN.md's resolution table is one
  /// case here, and the cases do the acting the resolver refuses to do.
  Future<void> _present(ScanOutcome outcome) async {
    switch (outcome) {
      // Ignored, and silently: the point of the window is that a fumbled
      // second read of the same label does nothing at all.
      case ScanRepeat():
        return;
      case ScanOneTaskDue(:final target, :final task, :final code):
        await _completeOne(target: target, task: task, code: code);
      case ScanSeveralTasksDue(:final target, :final tasks, :final code):
        await _showTasksSheet(target: target, tasks: tasks, code: code);
      case ScanNothingDue(:final target):
        await _showTarget(target);
      case ScanUnknownCode(:final code):
        await _offerToBind(code);
    }
  }

  /// One task due: complete it, buzz, toast, and leave five seconds to undo.
  ///
  /// The completion is written immediately rather than held back for the length
  /// of the undo window — undo is a tombstone and a recomputation (ADR 0004),
  /// so the task has already rescheduled by the time the toast appears.
  Future<void> _completeOne({
    required Target target,
    required Task task,
    required ScannedCode code,
  }) async {
    final repository = ref.read(taskRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    await HapticFeedback.mediumImpact();
    final completion = await repository.recordCompletion(
      task.id,
      source: code.kind.completionSource,
    );

    // Back to where the scan started from, so the due list is what you see
    // updating. The toast is shown on the app's messenger rather than this
    // screen's, which is why it survives the pop.
    if (navigator.canPop()) navigator.pop();

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Completed ${task.title} at ${target.name}'),
          duration: scanUndoWindow,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => repository.undoCompletion(completion),
          ),
        ),
      );
  }

  /// Two or more due: a sheet listing them, each tickable (ADR 0008 — a scan
  /// resolves to a set of tasks, so this disambiguation is the price of binding
  /// codes to targets rather than to tasks).
  Future<void> _showTasksSheet({
    required Target target,
    required List<Task> tasks,
    required ScannedCode code,
  }) async {
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _ScanTasksSheet(target: target, tasks: tasks, source: code),
    );
  }

  /// Nothing due: show what is tracked here and complete nothing.
  Future<void> _showTarget(Target target) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TargetDetailScreen(targetId: target.id),
      ),
    );
  }

  /// A code nem does not know: offer to bind it to a target (PLAN.md).
  Future<void> _offerToBind(ScannedCode code) async {
    final bound = await showModalBottomSheet<Target>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BindSheet(code: code),
    );
    if (bound == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${code.kind.displayLabel} bound to ${bound.name}. '
            'Scan it again to complete what is due.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan'),
        actions: [
          if (controller != null)
            IconButton(
              icon: const Icon(Icons.flashlight_on_outlined),
              tooltip: 'Torch',
              onPressed: controller.toggleTorch,
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          widget.previewBuilder?.call(context, _onScanned) ??
              MobileScanner(
                controller: controller,
                onDetect: (capture) {
                  for (final barcode in capture.barcodes) {
                    final raw = barcode.rawValue;
                    if (raw != null && raw.isNotEmpty) {
                      unawaited(_onScanned(raw));
                      return;
                    }
                  }
                },
              ),
          const Align(alignment: Alignment.bottomCenter, child: _ScanHint()),
        ],
      ),
    );
  }
}

class _ScanHint extends StatelessWidget {
  const _ScanHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              'Point at a label to complete what is due there.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet for two or more tasks due at one target.
///
/// Each row completes on its first tap and takes it back on the second, so the
/// undo is the tick itself rather than a toast that has to outlive a sheet.
class _ScanTasksSheet extends ConsumerStatefulWidget {
  const _ScanTasksSheet({
    required this.target,
    required this.tasks,
    required this.source,
  });

  final Target target;
  final List<Task> tasks;
  final ScannedCode source;

  @override
  ConsumerState<_ScanTasksSheet> createState() => _ScanTasksSheetState();
}

class _ScanTasksSheetState extends ConsumerState<_ScanTasksSheet> {
  /// The completion each ticked task produced, so a second tap can tombstone
  /// exactly the row this sheet wrote.
  final _completed = <String, Completion>{};

  Future<void> _toggle(Task task) async {
    final repository = ref.read(taskRepositoryProvider);
    final existing = _completed[task.id];
    if (existing != null) {
      await repository.undoCompletion(existing);
      if (mounted) setState(() => _completed.remove(task.id));
      return;
    }
    await HapticFeedback.selectionClick();
    final completion = await repository.recordCompletion(
      task.id,
      source: widget.source.kind.completionSource,
    );
    if (mounted) setState(() => _completed[task.id] = completion);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Due at ${widget.target.name}',
              style: theme.textTheme.titleMedium,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final task in widget.tasks)
                  CheckboxListTile(
                    key: ValueKey('scan-task-${task.id}'),
                    value: _completed.containsKey(task.id),
                    onChanged: (_) => _toggle(task),
                    title: Text(task.title),
                    subtitle: Text(
                      task.dueDate == null
                          ? 'No due date'
                          : 'Due ${formatDueDate(task.dueDate!)}',
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The sheet offering to bind an unrecognised code to a target.
///
/// Pops the target it bound to, or null when nothing was chosen.
class _BindSheet extends ConsumerWidget {
  const _BindSheet({required this.code});

  final ScannedCode code;

  Future<void> _bind(BuildContext context, WidgetRef ref, Target target) async {
    final navigator = Navigator.of(context);
    await ref
        .read(bindingRepositoryProvider)
        .bind(targetId: target.id, kind: code.kind, value: code.value);
    navigator.pop(target);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final targets = ref.watch(targetListProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text(
              'Unrecognised ${code.kind.displayLabel.toLowerCase()}',
              style: theme.textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              code.isScanUri
                  ? 'This label is not bound to anything on this device. '
                        'Bind it to a target:'
                  : 'Bind ${code.value} to a target:',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Flexible(
            child: targets.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load targets.\n$error'),
              ),
              data: (data) => data.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'There are no targets yet. Create one, then scan '
                        'this code again.',
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final target in data)
                          ListTile(
                            key: ValueKey('bind-to-${target.id}'),
                            title: Text(target.name),
                            subtitle: target.description == null
                                ? null
                                : Text(target.description!),
                            onTap: () => _bind(context, ref, target),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
