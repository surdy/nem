import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/binding.dart';
import '../domain/due_status.dart';
import '../domain/target.dart';
import '../domain/task.dart';
import 'due_list_screen.dart' show formatDueDate;
import 'target_form_screen.dart';
import 'target_label_screen.dart';

/// One target and the work done on it.
///
/// This is also the screen a scan of an unfinished target will land on in P2 —
/// "everything tracked here, and when it is next due" (PLAN.md — Resolution).
class TargetDetailScreen extends ConsumerWidget {
  const TargetDetailScreen({super.key, required this.targetId});

  final String targetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(targetProvider(targetId)).value;

    return Scaffold(
      appBar: AppBar(
        title: Text(target?.name ?? 'Target'),
        actions: [
          if (target != null)
            PopupMenuButton<_TargetAction>(
              onSelected: (action) => switch (action) {
                _TargetAction.rename => _edit(context, target),
                _TargetAction.label => _showLabel(context, target),
                _TargetAction.delete => _confirmDelete(context, ref, target),
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _TargetAction.rename,
                  child: Text('Rename'),
                ),
                PopupMenuItem(value: _TargetAction.label, child: Text('Label')),
                PopupMenuItem(
                  value: _TargetAction.delete,
                  child: Text('Delete target'),
                ),
              ],
            ),
        ],
      ),
      body: target == null
          ? const _Message(text: 'This target has been deleted.')
          : _TargetBody(target: target),
    );
  }

  void _edit(BuildContext context, Target target) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TargetFormScreen(target: target)),
    );
  }

  /// The printable QR label for this target (CONTEXT.md — "Label").
  void _showLabel(BuildContext context, Target target) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TargetLabelScreen(target: target),
      ),
    );
  }

  /// Deleting a target is not deleting its work, and the dialog says so —
  /// otherwise the safe-looking move is to leave dead targets lying around.
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Target target,
  ) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${target.name}?'),
        content: const Text(
          'Its tasks are kept, and stop being attached to any target.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(targetRepositoryProvider).softDeleteTarget(target.id);
    navigator.pop();
  }
}

enum _TargetAction { rename, label, delete }

class _TargetBody extends ConsumerWidget {
  const _TargetBody({required this.target});

  final Target target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider);
    final tasks = ref.watch(targetTasksProvider(target.id));
    final description = target.description;

    return tasks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _Message(text: 'Could not load tasks.\n$error'),
      data: (data) => ListView(
        children: [
          if (description != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                description,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'TASKS',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(letterSpacing: 1.2),
            ),
          ),
          if (data.isEmpty)
            const _Message(text: 'No tasks here yet.')
          else
            for (final task in data) _TaskTile(task: task, now: now),
          _Codes(targetId: target.id),
        ],
      ),
    );
  }
}

/// The scannable codes bound to this target (CONTEXT.md — "Binding").
///
/// Visible so a mis-bound barcode can be taken off again: binding is one tap
/// from a scan, so unbinding has to be reachable from somewhere.
class _Codes extends ConsumerWidget {
  const _Codes({required this.targetId});

  final String targetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bindings = ref.watch(targetBindingsProvider(targetId)).value;
    if (bindings == null || bindings.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            'CODES',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(letterSpacing: 1.2),
          ),
        ),
        for (final binding in bindings)
          ListTile(
            key: ValueKey('binding-${binding.id}'),
            leading: Icon(switch (binding.kind) {
              BindingKind.tag => Icons.nfc,
              BindingKind.label => Icons.qr_code_2,
              BindingKind.barcode => Icons.barcode_reader,
            }),
            title: Text(binding.kind.displayLabel),
            subtitle: Text(
              binding.kind == BindingKind.label
                  ? labelUriFor(binding.value)
                  : binding.value,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.link_off),
              tooltip: 'Unbind',
              onPressed: () =>
                  ref.read(bindingRepositoryProvider).unbind(binding.id),
            ),
          ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.now});

  final Task task;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = task.dueDate;
    final late = due == null ? null : overdueLabel(due, now);

    return ListTile(
      title: Text(task.title),
      subtitle: Text(
        due == null
            ? 'No due date'
            : ['Due ${formatDueDate(due)}', ?late].join(' · '),
        style: late == null
            ? null
            : theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
  );
}
