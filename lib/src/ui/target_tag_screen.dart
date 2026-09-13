import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/binding.dart';
import '../domain/target.dart';
import '../nfc/tag_gateway.dart';
import 'target_label_screen.dart';

/// Writing a target's tag: hold a blank NTAG against the phone and it comes
/// away carrying `nem://t/<uuid>` (ADR 0009).
///
/// Provisioning is writing the code *and* binding it (CONTEXT.md —
/// "Provisioning"), and in that order: a tag that failed to take the write must
/// not leave a binding behind claiming it did.
///
/// The tag carries the target's own uuid, exactly as the printed label does, so
/// a target can wear both and reprinting or rewriting either is free.
class TargetTagScreen extends ConsumerStatefulWidget {
  const TargetTagScreen({super.key, required this.target});

  final Target target;

  @override
  ConsumerState<TargetTagScreen> createState() => _TargetTagScreenState();
}

class _TargetTagScreenState extends ConsumerState<TargetTagScreen> {
  /// Null while the first availability check is in flight.
  TagAvailability? _availability;

  /// Set while a session is open and waiting for a tag.
  bool _writing = false;

  /// The last thing that happened, or null before anything has.
  TagWriteOutcome? _outcome;

  /// Read once and held, rather than read through `ref` on demand: `dispose`
  /// needs it to close the session, and reading a provider from a widget that
  /// is already on its way out is not allowed.
  late final TagGateway _tags;

  @override
  void initState() {
    super.initState();
    _tags = ref.read(tagGatewayProvider);
    _check();
  }

  @override
  void dispose() {
    // The iOS sheet outlives the screen that raised it unless it is told not
    // to, and a sheet asking for a tag after its screen has gone is a sheet
    // nothing is listening to.
    if (_writing) unawaited(_tags.stop());
    super.dispose();
  }

  /// Asks the hardware what it can do, every time rather than once: NFC can be
  /// switched off while this screen is on top of it.
  Future<void> _check() async {
    final availability = await _tags.availability();
    if (mounted) setState(() => _availability = availability);
  }

  Future<void> _write() async {
    if (_writing) return;
    setState(() {
      _writing = true;
      _outcome = null;
    });

    final uri = labelUriFor(widget.target.id);
    final outcome = await _tags.writeUri(
      uri,
      prompt: 'Hold a blank tag against the top of the phone.',
    );

    // Only a tag that really took the URI gets a binding. `bind` re-points
    // rather than duplicates, so writing the same target's tag twice — a second
    // tag for the same boiler, or a rewrite after a failure — is one row.
    if (outcome is TagWritten) {
      await HapticFeedback.mediumImpact();
      await ref
          .read(bindingRepositoryProvider)
          .bind(
            targetId: widget.target.id,
            kind: BindingKind.tag,
            value: widget.target.id,
          );
    }

    if (!mounted) return;
    setState(() {
      _writing = false;
      _outcome = outcome;
    });
  }

  Future<void> _cancel() async {
    await _tags.stop();
    if (mounted) setState(() => _writing = false);
  }

  void _showLabel() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TargetLabelScreen(target: widget.target),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tag')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            widget.target.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          ...switch (_availability) {
            null => const [Center(child: CircularProgressIndicator())],
            TagAvailability.unsupported => _unsupported(context),
            TagAvailability.disabled => _disabled(context),
            TagAvailability.enabled => _ready(context),
          },
        ],
      ),
    );
  }

  /// No NFC hardware — or a platform without it. Scanning is not the only way
  /// to reach a target, so this offers the one that needs no radio at all.
  List<Widget> _unsupported(BuildContext context) => [
    const _Note(
      key: ValueKey('tag-unsupported'),
      text:
          'This device cannot write NFC tags, so nem cannot provision one '
          'here. A printed label does the same job and scans with the camera.',
    ),
    const SizedBox(height: 16),
    OutlinedButton.icon(
      key: const ValueKey('tag-use-label'),
      onPressed: _showLabel,
      icon: const Icon(Icons.qr_code_2),
      label: const Text('Print a label instead'),
    ),
  ];

  /// The hardware is there and switched off. Android only — an iPhone has no
  /// NFC toggle to ask about.
  List<Widget> _disabled(BuildContext context) => [
    const _Note(
      key: ValueKey('tag-disabled'),
      text:
          'NFC is switched off. Turn it on in the system settings, then check '
          'again.',
    ),
    const SizedBox(height: 16),
    OutlinedButton.icon(
      key: const ValueKey('tag-recheck'),
      onPressed: _check,
      icon: const Icon(Icons.refresh),
      label: const Text('Check again'),
    ),
  ];

  List<Widget> _ready(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = _outcome;
    return [
      Text(
        'Hold a blank NTAG against the top of the phone and nem will write '
        'its address to it. Stick it on the thing, and scanning it records '
        'the work due there.',
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: 24),
      Center(
        child: SelectableText(
          labelUriFor(widget.target.id),
          style: theme.textTheme.bodySmall,
        ),
      ),
      const SizedBox(height: 24),
      if (_writing) ...[
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 16),
        const _Note(
          key: ValueKey('tag-waiting'),
          text: 'Waiting for a tag. Hold it still against the phone.',
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          key: const ValueKey('cancel-tag'),
          onPressed: _cancel,
          child: const Text('Cancel'),
        ),
      ] else
        FilledButton.icon(
          key: const ValueKey('write-tag'),
          onPressed: _write,
          icon: const Icon(Icons.nfc),
          label: const Text('Write the tag'),
        ),
      if (outcome != null && !_writing) ...[
        const SizedBox(height: 24),
        _Outcome(outcome: outcome),
      ],
    ];
  }
}

/// What a write attempt came to, in words somebody holding a sticker can act
/// on.
///
/// One case per [TagWriteOutcome], which is the point of them being separate
/// outcomes: "it did not work" is not advice, and "this tag is too small" is.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.outcome});

  final TagWriteOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, text, detail) = switch (outcome) {
      TagWritten() => (
        Icons.check_circle_outline,
        'Written. Stick it on the thing and scan it to record the work done '
            'there.',
        null,
      ),
      TagTooSmall(:final needed, :final capacity) => (
        Icons.straighten,
        'This tag has not got the room: nem needs $needed bytes and it holds '
            '$capacity. An NTAG215 or NTAG216 has plenty.',
        null,
      ),
      TagReadOnly() => (
        Icons.lock_outline,
        'This tag is locked and can never be written again. Use a blank one.',
        null,
      ),
      TagUnformatted() => (
        Icons.help_outline,
        'This tag has never been formatted, and iOS cannot format one. Write '
            'it from an Android phone, or use a tag that ships formatted.',
        null,
      ),
      TagWriteCancelled() => (Icons.info_outline, 'No tag was written.', null),
      // Deliberately vague about the cause, because the platform is: an
      // over-capacity write, a tag pulled away and an RF glitch all arrive as
      // the same bare error, so the only honest advice is to try again.
      TagWriteFailed(:final detail) => (
        Icons.error_outline,
        'Could not write the tag. Hold it flat against the phone until nem '
            'says it is done, and try again.',
        detail,
      ),
    };

    final success = outcome is TagWritten;
    return Column(
      key: const ValueKey('tag-outcome'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: success ? null : theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ],
        ),
        if (detail != null) ...[
          const SizedBox(height: 8),
          Text(detail, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodyMedium);
}
