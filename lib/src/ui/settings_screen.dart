import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/digest.dart';
import '../notifications/digest_notifier.dart';

/// Where the digest is switched on and given a time (CONTEXT.md — "Digest").
///
/// Per-task reminders are a separate setting on the task itself (CONTEXT.md —
/// "Reminder"), and do not belong on this screen.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Writes the settings, then puts the pending notifications in step.
  Future<void> _save(DigestSettings settings) async {
    await ref.read(digestSettingsRepositoryProvider).write(settings);
    ref.invalidate(digestSettingsProvider);

    final scheduler = ref.read(digestSchedulerProvider);
    if (settings.isEnabled) {
      await scheduler.refresh();
    } else {
      // Switching off has to take back what is already pending; leaving the
      // window in place would keep announcing for another fortnight.
      await scheduler.clear();
    }
  }

  /// Asks for permission at the moment the user asks for the digest.
  ///
  /// One of the two places nem prompts; the other is switching on a task's
  /// reminder, on the task detail screen. On iOS the system prompt appears
  /// exactly once in the life of an install, so it is spent where the user has
  /// just said they want notifications rather than on first launch — whichever
  /// of the two they reach first.
  ///
  /// A refusal does not undo the switch. The digest stays on and schedules as
  /// normal; it simply does not appear until notifications are allowed again,
  /// and the screen says so.
  Future<void> _setEnabled(DigestSettings settings, bool isEnabled) async {
    if (isEnabled) {
      final notifier = ref.read(digestNotifierProvider);
      if (!(await notifier.permission()).isGranted) {
        await notifier.requestPermission();
      }
      ref.invalidate(digestPermissionProvider);
    }
    await _save(settings.copyWith(isEnabled: isEnabled));
  }

  Future<void> _pickTime(DigestSettings settings) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: settings.time.hour,
        minute: settings.time.minute,
      ),
      helpText: 'Digest time',
    );
    if (picked == null) return;
    await _save(
      settings.copyWith(
        time: DigestTime(hour: picked.hour, minute: picked.minute),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(digestSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Could not load settings.\n$error'),
        ),
        data: (data) => _DigestSettingsList(
          settings: data,
          onEnabledChanged: (value) => _setEnabled(data, value),
          onTimeTapped: () => _pickTime(data),
        ),
      ),
    );
  }
}

class _DigestSettingsList extends ConsumerWidget {
  const _DigestSettingsList({
    required this.settings,
    required this.onEnabledChanged,
    required this.onTimeTapped,
  });

  final DigestSettings settings;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onTimeTapped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permission = ref.watch(digestPermissionProvider).value;
    final isBlocked =
        settings.isEnabled && permission == NotificationPermission.denied;

    return ListView(
      children: [
        const _SectionHeading(text: 'DAILY DIGEST'),
        SwitchListTile(
          title: const Text('Daily digest'),
          subtitle: const Text('One notification a day listing what is due.'),
          value: settings.isEnabled,
          onChanged: onEnabledChanged,
        ),
        ListTile(
          title: const Text('Time'),
          subtitle: Text(
            TimeOfDay(
              hour: settings.time.hour,
              minute: settings.time.minute,
            ).format(context),
          ),
          enabled: settings.isEnabled,
          onTap: onTimeTapped,
          trailing: const Icon(Icons.schedule),
        ),
        if (isBlocked) const _PermissionNotice(),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          letterSpacing: 1.2,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Shown when the digest is on but the OS will not deliver it.
///
/// Deliberately not a dialog and not a second prompt: iOS will not show the
/// system prompt again, so the only thing nem can honestly do is say what is
/// wrong and where it is fixed.
class _PermissionNotice extends StatelessWidget {
  const _PermissionNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Card(
        color: theme.colorScheme.errorContainer,
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.notifications_off_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Notifications are turned off for nem, so the digest will '
                  'not appear. Allow them in your system settings.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
