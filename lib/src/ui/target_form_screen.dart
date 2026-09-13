import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/target.dart';

/// Creates a target, or renames one that already exists.
///
/// One form for both, because naming a target and renaming it are the same two
/// fields; [target] is what decides which.
class TargetFormScreen extends ConsumerStatefulWidget {
  const TargetFormScreen({super.key, this.target});

  /// The target being edited, or null when creating one.
  final Target? target;

  @override
  ConsumerState<TargetFormScreen> createState() => _TargetFormScreenState();
}

class _TargetFormScreenState extends ConsumerState<TargetFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: widget.target?.name ?? '',
  );
  late final _descriptionController = TextEditingController(
    text: widget.target?.description ?? '',
  );

  bool _saving = false;

  bool get _isEdit => widget.target != null;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final repository = ref.read(targetRepositoryProvider);
      final existing = widget.target;
      if (existing == null) {
        await repository.createTarget(
          name: _nameController.text,
          description: _descriptionController.text,
        );
      } else {
        await repository.updateTarget(
          id: existing.id,
          name: _nameController.text,
          description: _descriptionController.text,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit target' : 'New target')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'The boiler',
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Give the target a name'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'In the airing cupboard, upstairs landing',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(
                _saving
                    ? 'Saving…'
                    : _isEdit
                    ? 'Save changes'
                    : 'Create target',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
