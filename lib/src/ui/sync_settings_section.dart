import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/supabase_connection.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_providers.dart';
import '../sync/sync_settings.dart';

/// Where the backend is named and signed into (#11).
///
/// Everything on this section is optional. nem with these fields empty is nem:
/// the due list, scanning, completions and the digest all work exactly as they
/// do with them filled in, because SQLite is the source of truth and the server
/// is a replica (ADR 0001). The screen says so, rather than presenting an empty
/// backend as something to fix.
class SyncSettingsSection extends ConsumerWidget {
  const SyncSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(syncSettingsProvider).value;
    if (settings == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeading(text: 'SYNC'),
        const _BackendFields(),
        if (settings.isConfigured) const _AccountTile(),
        if (settings.isConfigured) const _SyncStatusTile(),
      ],
    );
  }
}

/// The base URL and the anon key (ADR 0002).
class _BackendFields extends ConsumerStatefulWidget {
  const _BackendFields();

  @override
  ConsumerState<_BackendFields> createState() => _BackendFieldsState();
}

class _BackendFieldsState extends ConsumerState<_BackendFields> {
  final _url = TextEditingController();
  final _anonKey = TextEditingController();
  bool _seeded = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _anonKey.dispose();
    super.dispose();
  }

  /// Fills the fields from what is stored, once.
  ///
  /// Only once: the settings are a live stream, and re-seeding on every emission
  /// would take the cursor away from someone halfway through typing a URL.
  void _seedOnce(SyncSettings settings) {
    if (_seeded) return;
    _seeded = true;
    _url.text = settings.url;
    _anonKey.text = settings.anonKey;
  }

  Future<void> _save() async {
    final settings = SyncSettings(url: _url.text, anonKey: _anonKey.text);
    final isEmpty =
        settings.url.trim().isEmpty && settings.anonKey.trim().isEmpty;
    if (!isEmpty && !settings.isConfigured) {
      setState(
        () => _error = settings.normalisedUrl == null
            ? 'That is not a URL nem can reach — it needs http:// or https://.'
            : 'An anon key is needed as well as a URL.',
      );
      return;
    }

    setState(() => _error = null);
    await ref.read(syncSettingsRepositoryProvider).write(settings);
    // Pointing nem somewhere new means everything it has is news there, which
    // `SyncEngine.seed` works out from the URL it last seeded for.
    await ref.read(syncStatusProvider.notifier).sync();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(syncSettingsProvider).value;
    if (settings == null) return const SizedBox.shrink();
    _seedOnce(settings);

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            settings.isConfigured
                ? 'nem keeps working with no network; sync catches the two '
                      'devices up when there is one.'
                : 'Optional. nem works fully without an account — this is only '
                      'for keeping a second device in step.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            key: const Key('sync-url'),
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              helperText: 'Supabase Cloud, or your own instance.',
              hintText: 'https://<project>.supabase.co',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _anonKey,
            key: const Key('sync-anon-key'),
            autocorrect: false,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'Anon key',
              helperText:
                  'Public, not a secret. RLS is what protects the data.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: _save,
              child: const Text('Save backend'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Magic-link sign-in, and who is signed in.
class _AccountTile extends ConsumerStatefulWidget {
  const _AccountTile();

  @override
  ConsumerState<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends ConsumerState<_AccountTile> {
  final _email = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final client = ref.read(supabaseClientProvider).value;
    if (client == null) return;

    setState(() => _sending = true);
    String message;
    try {
      await sendMagicLink(client, _email.text);
      message = 'Check ${_email.text.trim()} for a link to sign in.';
    } on Object catch (error) {
      message = 'Could not send the link: $error';
    }
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _signOut() async {
    final client = ref.read(supabaseClientProvider).value;
    await client?.auth.signOut();
    ref.invalidate(syncAccountProvider);
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(syncAccountProvider).value;

    if (account != null) {
      return ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: Text(account),
        subtitle: const Text('Signed in'),
        trailing: TextButton(
          onPressed: _signOut,
          child: const Text('Sign out'),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _email,
            key: const Key('sync-email'),
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Email',
              helperText: 'A link is emailed; there is no password.',
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: _sending ? null : _send,
              child: Text(_sending ? 'Sending…' : 'Send magic link'),
            ),
          ),
        ],
      ),
    );
  }
}

/// What sync last did, and a way to ask it to do it again.
class _SyncStatusTile extends ConsumerWidget {
  const _SyncStatusTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(syncStatusProvider);
    final pending = ref.watch(outboxPendingProvider).value ?? 0;
    // Who is signed in comes from the session rather than from the last sync's
    // status, which only learns it once a sync has run.
    final isSignedIn = ref.watch(syncAccountProvider).value != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.sync),
          title: Text(
            _summary(status, pending: pending, isSignedIn: isSignedIn),
          ),
          subtitle: status.lastError == null
              ? null
              : Text(
                  status.isAuthFailure
                      ? 'Sign in again: ${status.lastError}'
                      : status.lastError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
          trailing: TextButton(
            onPressed: status.isSyncing
                ? null
                : () => ref.read(syncStatusProvider.notifier).sync(),
            child: const Text('Sync now'),
          ),
        ),
      ],
    );
  }

  String _summary(
    SyncStatus status, {
    required int pending,
    required bool isSignedIn,
  }) {
    if (status.isSyncing) return 'Syncing…';
    if (!isSignedIn) return 'Not signed in';
    if (pending > 0) {
      return pending == 1
          ? '1 change waiting to be sent'
          : '$pending changes waiting to be sent';
    }
    if (status.lastError != null) return 'Last sync did not finish';
    return 'Everything is sent';
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
