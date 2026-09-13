import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tag_launch.dart';

/// The one channel nem's own Android code answers on. Named for what it
/// carries rather than for the plugin it is not.
@visibleForTesting
const tagLaunchChannel = MethodChannel('nem/tag_launch');

/// [TagLaunchGateway] over that channel.
///
/// ## Why a channel of nem's own, and not `app_links` or Flutter's deep linking
///
/// `nfc_manager` reads no launch intent at all — there is no `NDEF_DISCOVERED`
/// or `onNewIntent` handling anywhere in it — so the cold-launch path needs
/// something else whatever else is decided. Three things ruled out the two
/// obvious candidates:
///
/// - Android 17 requires the receiving activity to hold
///   `DISPATCH_NFC_MESSAGE`, which means a dedicated activity that is not the
///   launcher (ADR 0009). That activity is nem's to write either way, and once
///   it exists, handing its URI to `MainActivity` is one `startActivity` call.
/// - `isTagIntentAllowed()` and `ACTION_CHANGE_TAG_INTENT_PREFERENCE` (Android
///   16) are not in any package, so a method channel exists here regardless.
///   Adding `app_links` would have meant a dependency *and* this channel, to
///   save the forty lines of Kotlin the channel already needs.
/// - Flutter's built-in deep linking routes an intent into the `Router` as a
///   route string, and nem is a `MaterialApp(home:)` with no route table. A
///   scanned tag is not a destination: it resolves to a completion, a sheet, a
///   target screen or an offer to bind (PLAN.md — Resolution), and three of
///   those four are not navigation. Adopting `Router` to express "resolve
///   this" as a URL would have been the larger change by far.
///
/// Everything that could be decided in Dart is: this class translates three
/// strings and holds a stream, and every judgement above it lives where a test
/// can reach it.
class PlatformTagLaunchGateway implements TagLaunchGateway {
  PlatformTagLaunchGateway({MethodChannel? channel, TargetPlatform? platform})
    : _channel = channel ?? tagLaunchChannel,
      _platform = platform ?? defaultTargetPlatform {
    if (_isAndroid) _channel.setMethodCallHandler(_onPlatformCall);
  }

  final MethodChannel _channel;
  final TargetPlatform _platform;

  final _uris = StreamController<String>.broadcast();

  /// ADR 0009: this is Android's gesture and iOS deliberately does not get it.
  bool get _isAndroid => _platform == TargetPlatform.android;

  @override
  Stream<String> get uris => _uris.stream;

  @override
  Future<String?> takeLaunchUri() => _ask<String>('takeLaunchUri');

  @override
  Future<TagLaunchPreference> preference() async =>
      switch (await _ask<String>('preference')) {
        'allowed' => TagLaunchPreference.allowed,
        'disallowed' => TagLaunchPreference.disallowed,
        _ => TagLaunchPreference.unsupported,
      };

  @override
  Future<void> showPreferenceScreen() => _ask<void>('showPreferenceScreen');

  Future<T?> _ask<T>(String method) async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<T>(method);
    } catch (_) {
      // A platform that does not answer is a platform that cannot launch nem
      // from a tag, which is the same thing as not being launched from one. It
      // is never a reason to take a screen down.
      return null;
    }
  }

  Future<void> _onPlatformCall(MethodCall call) async {
    if (call.method != 'tagLaunched') return;
    final uri = call.arguments;
    if (uri is String && uri.isNotEmpty && !_uris.isClosed) _uris.add(uri);
  }

  /// Releases the stream. The gateway lives as long as the app does, so this is
  /// for tests and for the provider's disposal.
  Future<void> dispose() async {
    if (_isAndroid) _channel.setMethodCallHandler(null);
    await _uris.close();
  }
}
