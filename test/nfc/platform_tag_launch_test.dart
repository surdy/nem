import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/nfc/platform_tag_launch.dart';
import 'package:nem/src/nfc/tag_launch.dart';

/// The Dart half of the launch seam, against a channel with nothing behind it.
///
/// The Kotlin half cannot be reached from here at all — from Android 17 only
/// the NFC system service may start the activity that receives a dispatch
/// (ADR 0009) — so what this pins down is everything on this side of the
/// channel: the three calls, what each string means, and the fact that an iPhone
/// never makes any of them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, Object?> answers;

  setUp(() {
    calls = [];
    answers = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(tagLaunchChannel, (call) async {
          calls.add(call);
          return answers[call.method];
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(tagLaunchChannel, null);
  });

  PlatformTagLaunchGateway android() {
    final gateway = PlatformTagLaunchGateway(platform: TargetPlatform.android);
    addTearDown(gateway.dispose);
    return gateway;
  }

  test('the launch URI is asked for, and asked for once', () async {
    answers['takeLaunchUri'] = 'nem://t/abc';
    expect(await android().takeLaunchUri(), 'nem://t/abc');
    expect(calls.single.method, 'takeLaunchUri');
  });

  test('no launch URI is an ordinary answer', () async {
    expect(await android().takeLaunchUri(), isNull);
  });

  test('a tap while nem is running arrives on the stream', () async {
    final gateway = android();
    final tapped = gateway.uris.first;

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          tagLaunchChannel.name,
          tagLaunchChannel.codec.encodeMethodCall(
            const MethodCall('tagLaunched', 'nem://t/abc'),
          ),
          null,
        );

    expect(await tapped, 'nem://t/abc');
  });

  test('every answer the preference can give', () async {
    answers['preference'] = 'allowed';
    expect(await android().preference(), TagLaunchPreference.allowed);

    answers['preference'] = 'disallowed';
    expect(await android().preference(), TagLaunchPreference.disallowed);

    answers['preference'] = 'unsupported';
    expect(await android().preference(), TagLaunchPreference.unsupported);
  });

  test('a platform that says nothing is one that cannot launch nem', () async {
    // A channel with no Kotlin behind it — which is every non-Android build,
    // and any Android where the call fails. Never an exception into a screen.
    answers['preference'] = null;
    expect(await android().preference(), TagLaunchPreference.unsupported);
  });

  test('the preference screen is the platform to raise, not nem', () async {
    await android().showPreferenceScreen();
    expect(calls.single.method, 'showPreferenceScreen');
  });

  test('an iPhone never asks the platform anything (ADR 0009)', () async {
    // iOS background-launches an app from a tag only for a URI on a domain
    // claimed through Universal Links, and ADR 0009 chose the custom scheme
    // instead. There is nothing to ask, so nothing is asked.
    final gateway = PlatformTagLaunchGateway(platform: TargetPlatform.iOS);
    addTearDown(gateway.dispose);

    expect(await gateway.takeLaunchUri(), isNull);
    expect(await gateway.preference(), TagLaunchPreference.unsupported);
    await gateway.showPreferenceScreen();

    expect(calls, isEmpty);
  });
}
