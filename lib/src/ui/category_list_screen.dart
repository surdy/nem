import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/category.dart';
import 'category_chips.dart';
import 'category_form_screen.dart';

/// Every category, and where they are made, renamed, recoloured and deleted
/// (CONTEXT.md — "Category").
///
/// Reached from Settings rather than from the bottom navigation, because a
/// category is not a place you go: it is a lens on the due list, and the lens
/// itself lives on the due list's filter. This screen is where the lenses are
/// kept.
class CategoryListScreen extends ConsumerWidget {
  const CategoryListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoryListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-category',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CategoryFormScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('New category'),
      ),
      body: categories.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            _Message(text: 'Could not load categories.\n$error'),
        data: (data) => data.isEmpty
            ? const _Message(
                text:
                    'No categories yet.\n'
                    'A category groups work across targets — kitchen, car, '
                    'admin — and the due list can be filtered down to one.',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final category in data)
                    _CategoryTile(category: category),
                ],
              ),
      ),
    );
  }
}

class _CategoryTile extends ConsumerWidget {
  const _CategoryTile({required this.category});

  final Category category;

  /// Deletes the category, once it is clear that is what was meant.
  ///
  /// The confirmation says what survives, because that is the part nobody can
  /// see: the tasks stay, with their schedules and their history — a category
  /// is a grouping, and deleting a grouping is not deleting the work.
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${category.name}?'),
        content: const Text(
          'The tasks in it are kept — they simply stop being in this '
          'category.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref
          .read(categoryRepositoryProvider)
          .softDeleteCategory(category.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: CategorySwatch(color: category.color, size: 20),
      title: Text(category.name),
      trailing: PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (value) async {
          switch (value) {
            case 'edit':
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CategoryFormScreen(category: category),
                ),
              );
            case 'delete':
              await _delete(context, ref);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CategoryFormScreen(category: category),
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
