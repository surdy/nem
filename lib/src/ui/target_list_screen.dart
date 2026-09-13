import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/target.dart';
import 'target_detail_screen.dart';
import 'target_form_screen.dart';

/// Everything work gets done on, alphabetically.
class TargetListScreen extends ConsumerWidget {
  const TargetListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = ref.watch(targetListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Targets')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const TargetFormScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('New target'),
      ),
      body: targets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _Message(text: 'Could not load targets.\n$error'),
        data: (data) => data.isEmpty
            ? const _Message(
                text:
                    'No targets yet.\n'
                    'A target is a place or object work is done on — '
                    'the boiler, the car, the front door.',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final target in data) _TargetTile(target: target),
                ],
              ),
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({required this.target});

  final Target target;

  @override
  Widget build(BuildContext context) {
    final description = target.description;
    return ListTile(
      title: Text(target.name),
      subtitle: description == null ? null : Text(description),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TargetDetailScreen(targetId: target.id),
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
