import 'dart:async';

import 'package:nem/src/nfc/tag_launch.dart';

/// Android's tap-to-launch, in software.
///
/// The one part of #9 that cannot be arranged anywhere but on a phone with a
/// real tag: from Android 17 the receiving activity holds
/// `DISPATCH_NFC_MESSAGE`, so only the NFC system service may start it and no
/// test and no `adb` command can (ADR 0009). Everything above the platform
/// channel — what a launch URI resolves to, what the window does to the second
/// tap, what a disallowed preference puts on screen — is exercised through
/// this.
class FakeTagLaunchGateway implements TagLaunchGateway {
  FakeTagLaunchGateway({
    this.launchUri,
    this.preferenceValue = TagLaunchPreference.allowed,
  });

  /// The URI nem was launched with, or null when it was opened by hand.
  /// Taken once, like the real one.
  String? launchUri;

  /// What [preference] answers. Mutable: it is a system setting and can change
  /// while a screen is looking at it.
  TagLaunchPreference preferenceValue;

  /// How many times the system's preference screen was asked for.
  int preferenceScreensShown = 0;

  final _uris = StreamController<String>.broadcast();

  /// Taps a tag while nem is already running.
  void tap(String uri) => _uris.add(uri);

  @override
  Stream<String> get uris => _uris.stream;

  @override
  Future<String?> takeLaunchUri() async {
    final uri = launchUri;
    launchUri = null;
    return uri;
  }

  @override
  Future<TagLaunchPreference> preference() async => preferenceValue;

  @override
  Future<void> showPreferenceScreen() async => preferenceScreensShown++;

  Future<void> dispose() => _uris.close();
}
