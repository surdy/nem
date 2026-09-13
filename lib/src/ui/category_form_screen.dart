import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/category.dart';

/// Creates a category, or renames and recolours one that already exists.
///
/// One form for both, the way `TargetFormScreen` is: naming a category and
/// renaming it are the same two fields, and [category] is what decides which.
class CategoryFormScreen extends ConsumerStatefulWidget {
  const CategoryFormScreen({super.key, this.category});

  /// The category being edited, or null when creating one.
  final Category? category;

  @override
  ConsumerState<CategoryFormScreen> createState() => _CategoryFormScreenState();
}

class _CategoryFormScreenState extends ConsumerState<CategoryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: widget.category?.name ?? '',
  );

  /// The swatch chosen, defaulting to the first one for a new category.
  ///
  /// A colour is always offered rather than opted into, because a category with
  /// no colour is indistinguishable from its neighbours in a list of chips —
  /// which is the one thing the colour is for. The column stays nullable all
  /// the same, so a category that arrives from an older build reads honestly.
  late int? _color = widget.category?.color ?? categorySwatches.first;

  bool _saving = false;

  bool get _isEdit => widget.category != null;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final repository = ref.read(categoryRepositoryProvider);
      final existing = widget.category;
      if (existing == null) {
        await repository.createCategory(
          name: _nameController.text,
          color: _color,
        );
      } else {
        await repository.updateCategory(
          id: existing.id,
          name: _nameController.text,
          color: _color,
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit category' : 'New category')),
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
                hintText: 'Kitchen',
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Give the category a name'
                  : null,
            ),
            const SizedBox(height: 24),
            Text('Colour', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final swatch in categorySwatches)
                  _SwatchButton(
                    // Keyed by the value it writes, so a test can pick one out
                    // by the colour it means rather than by its position.
                    key: ValueKey('swatch-$swatch'),
                    color: swatch,
                    isSelected: _color == swatch,
                    onTap: () => setState(() => _color = swatch),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(
                _saving
                    ? 'Saving…'
                    : _isEdit
                    ? 'Save changes'
                    : 'Create category',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.color,
    required this.isSelected,
    required this.onTap,
    super.key,
  });

  final int color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: isSelected,
      button: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Color(color),
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? theme.colorScheme.onSurface : Colors.black12,
              width: isSelected ? 3 : 1,
            ),
          ),
          child: isSelected
              ? const Icon(Icons.check, size: 20, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
