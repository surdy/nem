import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/interval_unit.dart';
import '../domain/schedule.dart';
import '../domain/target.dart';
import 'due_list_screen.dart' show formatDueDate;

/// Creates a task with a floating schedule.
class CreateTaskScreen extends ConsumerStatefulWidget {
  const CreateTaskScreen({super.key});

  @override
  ConsumerState<CreateTaskScreen> createState() => _CreateTaskScreenState();
}

class _CreateTaskScreenState extends ConsumerState<CreateTaskScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _intervalController = TextEditingController(text: '3');

  IntervalUnit _unit = IntervalUnit.day;

  /// The target this task is done on, or null for work attached to nothing
  /// physical (ADR 0008).
  String? _targetId;

  late DateTime _startDate = _today();
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  int? get _intervalN => int.tryParse(_intervalController.text.trim());

  /// The due date this task will have, derived live from the schedule the form
  /// describes. It is shown, never edited (ADR 0004).
  DateTime? get _previewDueDate {
    final n = _intervalN;
    if (n == null || n < 1) return null;
    return floatingDueDate(
      FloatingSchedule(
        intervalN: n,
        intervalUnit: _unit,
        startDate: _startDate,
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(taskRepositoryProvider)
          .createFloatingTask(
            title: _titleController.text.trim(),
            notes: _notesController.text,
            targetId: _targetId,
            intervalN: _intervalN!,
            intervalUnit: _unit,
            startDate: _startDate,
          );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _startDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final previewDue = _previewDueDate;
    final targets = ref.watch(targetListProvider).value ?? const <Target>[];

    return Scaffold(
      appBar: AppBar(title: const Text('New task')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Replace the water filter',
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Give the task a title'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            // Offered only once there is something to choose. A target is a
            // physical place or object, so the list is empty until one has been
            // created, and an empty dropdown is just a dead control.
            if (targets.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: _targetId,
                decoration: const InputDecoration(
                  labelText: 'Target (optional)',
                ),
                items: [
                  const DropdownMenuItem<String?>(child: Text('No target')),
                  for (final target in targets)
                    DropdownMenuItem<String?>(
                      value: target.id,
                      child: Text(target.name),
                    ),
                ],
                onChanged: (value) => setState(() => _targetId = value),
              ),
            ],
            const SizedBox(height: 32),
            Text(
              'FLOATING SCHEDULE',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Due date is measured forward from the last completion.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: TextFormField(
                    controller: _intervalController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Every'),
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final n = int.tryParse((value ?? '').trim());
                      if (n == null || n < 1) return 'At least 1';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<IntervalUnit>(
                    initialValue: _unit,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: [
                      for (final unit in IntervalUnit.values)
                        DropdownMenuItem(
                          value: unit,
                          child: Text(
                            unit.labelFor(_intervalN ?? 1).split(' ').last,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _unit = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start date'),
              subtitle: Text(formatDueDate(_startDate)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: _pickStartDate,
            ),
            if (previewDue != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('First due'),
                subtitle: Text(formatDueDate(previewDue)),
                enabled: false,
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Create task'),
            ),
          ],
        ),
      ),
    );
  }
}
