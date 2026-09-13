import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';

import 'ndef_uri.dart';
import 'tag_gateway.dart';

/// [TagGateway] over `nfc_manager`.
///
/// The only file in nem that imports the plugin. It is deliberately thin: it
/// starts and stops sessions, turns one NDEF message into a string and one
/// string into an NDEF message, and translates the platform's failures into the
/// outcomes the rest of the app reasons about. Every judgement it makes —
/// which failures are distinct, when a session may start — lives in
/// `tag_gateway.dart`, where it can be tested.
class NfcTagGateway implements TagGateway {
  NfcTagGateway({TargetPlatform? platform})
    : _platform = platform ?? defaultTargetPlatform;

  final TargetPlatform _platform;

  /// Set while a read session is running, so starting twice is a no-op rather
  /// than two overlapping sessions.
  bool _reading = false;

  /// Every tag type either platform will poll for. Left wide rather than
  /// narrowed to the ISO 14443 that an NTAG answers on: a tag somebody else
  /// stuck to something is a code nem can offer to bind, and refusing to see it
  /// would make that offer impossible.
  static const _polling = {
    NfcPollingOption.iso14443,
    NfcPollingOption.iso15693,
    NfcPollingOption.iso18092,
  };

  /// Whether the plugin will talk to this platform at all.
  ///
  /// `NfcManager.instance` throws `UnsupportedError` on anything that is not a
  /// phone, at first access — so this is checked before every access rather
  /// than once in the constructor.
  bool get _isMobile =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  @override
  TagSessionPresentation get presentation => _platform == TargetPlatform.iOS
      ? TagSessionPresentation.systemSheet
      : TagSessionPresentation.background;

  @override
  Future<TagAvailability> availability() async {
    if (!_isMobile) return TagAvailability.unsupported;
    try {
      return switch (await NfcManager.instance.checkAvailability()) {
        NfcAvailability.enabled => TagAvailability.enabled,
        NfcAvailability.disabled => TagAvailability.disabled,
        NfcAvailability.unsupported => TagAvailability.unsupported,
      };
    } catch (_) {
      // A device that cannot answer the question cannot scan either, and a
      // thrown availability check must not take a screen down with it.
      return TagAvailability.unsupported;
    }
  }

  @override
  Future<void> startReading({
    required void Function(TagRead read) onRead,
    String? prompt,
  }) async {
    if (!_isMobile || _reading) return;
    _reading = true;
    try {
      await NfcManager.instance.startSession(
        pollingOptions: _polling,
        alertMessageIos: prompt,
        // nem closes the sheet itself, once it knows what the tag meant, so
        // that the sheet can say so.
        invalidateAfterFirstReadIos: false,
        onSessionErrorIos: (_) => _reading = false,
        onDiscovered: (tag) async => onRead(await _read(tag)),
      );
    } catch (error) {
      _reading = false;
      onRead(TagUnreadable('$error'));
    }
  }

  @override
  Future<TagWriteOutcome> writeUri(String uri, {String? prompt}) async {
    if (!_isMobile) return const TagWriteFailed('NFC is not supported here');

    final message = ndefUriMessage(uri);
    final outcome = Completer<TagWriteOutcome>();

    // Android calls back for every tag that comes near, and a second callback
    // while the first write is still in flight would write the same URI to
    // whatever else happens to be on the desk.
    var claimed = false;

    void finish(TagWriteOutcome result) {
      if (!outcome.isCompleted) outcome.complete(result);
    }

    try {
      await NfcManager.instance.startSession(
        pollingOptions: _polling,
        alertMessageIos: prompt,
        invalidateAfterFirstReadIos: false,
        // The session ending by itself — a timeout, or the user dismissing the
        // sheet — is the one non-outcome, and it is silent on purpose.
        onSessionErrorIos: (_) => finish(const TagWriteCancelled()),
        onDiscovered: (tag) async {
          if (claimed) return;
          claimed = true;
          final result = await _write(tag, message);
          await stop(
            message: result is TagWritten ? 'Tag written' : null,
            errorMessage: result is TagWritten ? null : 'Could not write it',
          );
          finish(result);
        },
      );
    } catch (error) {
      return TagWriteFailed('$error');
    }

    return outcome.future;
  }

  @override
  Future<void> stop({String? message, String? errorMessage}) async {
    _reading = false;
    if (!_isMobile) return;
    try {
      await NfcManager.instance.stopSession(
        alertMessageIos: message,
        errorMessageIos: errorMessage,
      );
    } catch (_) {
      // Stopping a session that has already ended is not a failure worth
      // propagating to a screen that is on its way out.
    }
  }

  /// What one discovered tag carries.
  Future<TagRead> _read(NfcTag tag) async {
    final ndef = Ndef.from(tag);
    if (ndef == null) return const TagUnreadable('This tag holds no NDEF data');
    try {
      final value = uriFromNdefMessage(ndef.cachedMessage ?? await ndef.read());
      return value == null
          ? const TagUnreadable('This tag holds nothing nem can read')
          : TagValueRead(value);
    } catch (error) {
      return TagUnreadable('$error');
    }
  }

  /// Writes [message] to one discovered tag.
  ///
  /// The capacity and lock checks happen here, before the write, because
  /// afterwards they are gone: Android reports an over-capacity write, a tag
  /// pulled away mid-write and an RF glitch as the same bare `IOException`.
  /// Anything that does throw is therefore [TagWriteFailed] and nothing more
  /// specific, however much the message looks like it might say otherwise.
  Future<TagWriteOutcome> _write(NfcTag tag, NdefMessage message) async {
    final ndef = Ndef.from(tag);

    if (ndef == null) {
      // A genuinely unformatted tag is NdefFormatable rather than Ndef, and
      // only Android can do anything about that. `NdefFormatableAndroid.from`
      // reads Android's own tag structure, so it is not merely useless on iOS —
      // calling it there fails the cast.
      if (_platform != TargetPlatform.android) return const TagUnformatted();
      final formatable = NdefFormatableAndroid.from(tag);
      if (formatable == null) return const TagUnformatted();
      try {
        await formatable.format(message);
        return const TagWritten();
      } catch (error) {
        return TagWriteFailed('$error');
      }
    }

    final refusal = refuseWrite(
      isWritable: ndef.isWritable,
      capacity: ndef.maxSize,
      messageSize: message.byteLength,
    );
    if (refusal != null) return refusal;

    try {
      await ndef.write(message: message);
      return const TagWritten();
    } catch (error) {
      return TagWriteFailed('$error');
    }
  }
}
