import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/category.dart';
import 'category_form_screen.dart';

/// One category, as a chip: its swatch and its name.
///
/// Small enough to sit in a row of them under a task, which is the point — a
/// task can be in several categories at once, so the display has to survive
/// being plural.
class CategoryChip extends StatelessWidget {
  const CategoryChip({required this.category, this.onDeleted, super.key});

  final Category category;

  /// Shown as a small clear button when given — used where the chip is an
  /// active filter that can be lifted.
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      avatar: CategorySwatch(color: category.color),
      label: Text(category.name),
      labelStyle: theme.textTheme.labelMedium,
      side: BorderSide.none,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      visualDensity: VisualDensity.compact,
      onDeleted: onDeleted,
      deleteButtonTooltipMessage: onDeleted == null
          ? null
          : 'Remove ${category.name} from the filter',
    );
  }
}

/// The coloured dot a category is recognised by.
class CategorySwatch extends StatelessWidget {
  const CategorySwatch({required this.color, this.size = 14, super.key});

  final int? color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Color(color ?? uncolouredCategorySwatch),
      shape: BoxShape.circle,
    ),
  );
}

/// Asks which categories something is in, and returns the answer.
///
/// Returns null when the sheet is dismissed without a decision, which is not
/// the same as returning an empty set — one means "leave it as it was", the
/// other means "in none of them".
///
/// One sheet for both jobs it has: choosing a task's categories, and choosing
/// which ones the due list is filtered to. They are the same question asked of
/// the same list, and a second implementation would be a second place for the
/// two to drift apart.
Future<Set<String>?> showCategorySelector({
  required BuildContext context,
  required Set<String> selected,
  required String title,
}) {
  return showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CategorySelectorSheet(selected: selected, title: title),
  );
}

class _CategorySelectorSheet extends ConsumerStatefulWidget {
  const _CategorySelectorSheet({required this.selected, required this.title});

  final Set<String> selected;
  final String title;

  @override
  ConsumerState<_CategorySelectorSheet> createState() =>
      _CategorySelectorSheetState();
}

class _CategorySelectorSheetState
    extends ConsumerState<_CategorySelectorSheet> {
  late final Set<String> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = ref.watch(categoryListProvider).value ?? const [];

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(widget.title, style: theme.textTheme.titleMedium),
            ),
            if (categories.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(
                  'No categories yet.\n'
                  'A category groups work across targets — kitchen, car, '
                  'admin.',
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final category in categories)
                      CheckboxListTile(
                        value: _selected.contains(category.id),
                        secondary: CategorySwatch(color: category.color),
                        title: Text(category.name),
                        onChanged: (isSelected) => setState(() {
                          if (isSelected ?? false) {
                            _selected.add(category.id);
                          } else {
                            _selected.remove(category.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('New category'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CategoryFormScreen(),
                      ),
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
