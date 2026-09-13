import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/binding_repository.dart';
import '../domain/completion.dart';
import '../domain/scan.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import 'due_list_screen.dart' show formatDueDate;
import 'target_detail_screen.dart';

/// Carrying out a decision the [ScanResolver] has already made.
///
/// Extracted from the scan screen so that the other way a scan can arrive —
/// Android tapping a tag while nem is closed (#9) — carries it out with the
/// same code rather than a second copy of it. Every branch of PLAN.md's
/// resolution table is one case here, and the cases do the acting the resolver
/// refuses to do: complete, buzz, toast, offer undo, show a sheet.
///
/// [dismiss] is how the screen that started the scan gets out of the way once
/// something has been completed. The scan screen pops itself, so the due list
/// is what you watch update; a tap that launched nem has nothing to pop and
/// passes null.
Future<void> presentScanOutcome(
  BuildContext context,
  WidgetRef ref,
  ScanOutcome outcome, {
  VoidCallback? dismiss,
}) async {
  switch (outcome) {
    // Ignored, and silently: the point of the window is that a fumbled second
    // read of the same label does nothing at all.
    case ScanRepeat():
      return;
    case ScanOneTaskDue(:final target, :final task, :final code):
      await _completeOne(
        context,
        ref,
        target: target,
        task: task,
        code: code,
        dismiss: dismiss,
      );
    case ScanSeveralTasksDue(:final target, :final tasks, :final code):
      await _showTasksSheet(context, target: target, tasks: tasks, code: code);
    case ScanNothingDue(:final target):
      await _showTarget(context, target);
    case ScanUnknownCode(:final code):
      await _offerToBind(context, code);
  }
}

/// One task due: complete it, buzz, toast, and leave five seconds to undo.
///
/// The completion is written immediately rather than held back for the length
/// of the undo window — undo is a tombstone and a recomputation (ADR 0004), so
/// the task has already rescheduled by the time the toast appears.
Future<void> _completeOne(
  BuildContext context,
  WidgetRef ref, {
  required Target target,
  required Task task,
  required ScannedCode code,
  required VoidCallback? dismiss,
}) async {
  final completions = ref.read(taskCompletionsProvider);
  final messenger = ScaffoldMessenger.of(context);

  await HapticFeedback.mediumImpact();
  final completion = await completions.record(
    task.id,
    source: code.kind.completionSource,
  );

  // Back to where the scan started from, so the due list is what you see
  // updating. The toast is shown on the app's messenger rather than one
  // screen's, which is why it survives the pop.
  dismiss?.call();

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Completed ${task.title} at ${target.name}'),
        duration: scanUndoWindow,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => completions.undo(completion),
        ),
      ),
    );
}

/// Two or more due: a sheet listing them, each tickable (ADR 0008 — a scan
/// resolves to a set of tasks, so this disambiguation is the price of binding
/// codes to targets rather than to tasks).
Future<void> _showTasksSheet(
  BuildContext context, {
  required Target target,
  required List<Task> tasks,
  required ScannedCode code,
}) async {
  await HapticFeedback.mediumImpact();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ScanTasksSheet(target: target, tasks: tasks, source: code),
  );
}

/// Nothing due: show what is tracked here and complete nothing.
Future<void> _showTarget(BuildContext context, Target target) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TargetDetailScreen(targetId: target.id),
    ),
  );
}

/// A code nem does not know: offer to bind it to a target (PLAN.md).
Future<void> _offerToBind(BuildContext context, ScannedCode code) async {
  final bound = await showModalBottomSheet<Target>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _BindSheet(code: code),
  );
  if (bound == null || !context.mounted) return;
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

/// How long the undo affordance stays on screen after a scan completes
/// something. The same five seconds the due list offers.
const scanUndoWindow = Duration(seconds: 5);

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
    final completions = ref.read(taskCompletionsProvider);
    final existing = _completed[task.id];
    if (existing != null) {
      await completions.undo(existing);
      if (mounted) setState(() => _completed.remove(task.id));
      return;
    }
    await HapticFeedback.selectionClick();
    final completion = await completions.record(
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
/// Pops the target it bound to, or null when nothing was chosen. A target can
/// be made from here: a barcode on a product is usually scanned before anybody
/// has thought to create the thing it is stuck to, and sending them away to the
/// targets screen would mean scanning it twice (#10).
class _BindSheet extends ConsumerStatefulWidget {
  const _BindSheet({required this.code});

  final ScannedCode code;

  @override
  ConsumerState<_BindSheet> createState() => _BindSheetState();
}

class _BindSheetState extends ConsumerState<_BindSheet> {
  /// Why the last attempt did not bind, or null.
  String? _refusal;

  ScannedCode get code => widget.code;

  Future<void> _bind(Target target) async {
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(bindingRepositoryProvider)
          .bindUnclaimed(
            targetId: target.id,
            kind: code.kind,
            value: code.value,
          );
    } on BindingConflict catch (conflict) {
      // Refused, and the sheet stays up: the code is in their hand and the
      // next move is theirs.
      if (mounted) setState(() => _refusal = conflict.message);
      return;
    }
    navigator.pop(target);
  }

  /// Names a target, creates it, and binds the code to it in one gesture.
  Future<void> _bindToNew() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewTargetDialog(),
    );
    if (name == null || !mounted) return;
    final target = await ref
        .read(targetRepositoryProvider)
        .createTarget(name: name);
    if (!mounted) return;
    await _bind(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targets = ref.watch(targetListProvider);
    final refusal = _refusal;

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
          if (refusal != null)
            Padding(
              key: const ValueKey('bind-refused'),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                refusal,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ListTile(
            key: const ValueKey('bind-to-new'),
            leading: const Icon(Icons.add),
            title: const Text('A new target'),
            onTap: _bindToNew,
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
                      child: Text('There is nothing else to bind it to yet.'),
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
                            onTap: () => _bind(target),
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

/// Names the target a scanned code is about to create.
///
/// A name and nothing else. Everything a target can carry is editable
/// afterwards, and a form in the way of a barcode already under the camera is a
/// form nobody wanted.
class _NewTargetDialog extends StatefulWidget {
  const _NewTargetDialog();

  @override
  State<_NewTargetDialog> createState() => _NewTargetDialogState();
}

class _NewTargetDialogState extends State<_NewTargetDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New target'),
    content: TextField(
      key: const ValueKey('new-target-name'),
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(
        labelText: 'Name',
        hintText: 'The boiler',
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('create-target'),
        onPressed: _submit,
        child: const Text('Create and bind'),
      ),
    ],
  );
}
