/// Tap-to-launch: the tag that starts nem rather than the tag nem was already
/// listening for (#9).
///
/// A second, narrower seam alongside [TagGateway], and deliberately not part of
/// it. The two have nothing in common but the word "tag": a gateway runs a
/// session while nem is on screen, and this delivers a URI the *operating
/// system* read off a tag before nem was running — through Android's intent
/// system, which no NFC session is involved in at all.
///
/// Android only, and by decision rather than omission. iOS background-launches
/// an app from a tag only for a URI on a domain claimed through Universal
/// Links, and ADR 0009 chose the custom scheme over buying a domain, so on an
/// iPhone this reports [TagLaunchPreference.unsupported], never emits, and the
/// app continues to require being open first.
library;

/// Whether the OS will let a tap on a tag launch nem.
///
/// Android 16 prompts on the first NFC intent an app receives and remembers the
/// answer permanently, so "the user said no once, months ago" is an ordinary
/// state to be in — and one nem cannot detect by waiting, because its symptom
/// is that nothing happens.
enum TagLaunchPreference {
  /// Tapping a tag opens nem.
  allowed,

  /// The user has disallowed it. Reversible, but only through the system's own
  /// screen — see [TagLaunchGateway.showPreferenceScreen].
  disallowed,

  /// Nothing to say: iOS, a phone with no NFC in it, or an Android older than
  /// the preference itself (API 36). Not a problem, and not something to
  /// mention on screen.
  unsupported,
}

/// The URIs the OS hands nem when a tag is tapped, and the one setting that can
/// stop it happening.
abstract interface class TagLaunchGateway {
  /// The URI nem was launched with, taken exactly once.
  ///
  /// The cold-launch half. Pulled rather than pushed because the intent arrives
  /// long before Dart is running: the platform holds it, hands it over when
  /// asked, and forgets it — so a rebuild of the Flutter engine cannot deliver
  /// the same tap twice.
  Future<String?> takeLaunchUri();

  /// URIs from taps that arrive while nem is already running.
  ///
  /// Broadcast, and never replays: a tap that arrives before anything is
  /// listening is [takeLaunchUri]'s job, not this one's.
  Stream<String> get uris;

  /// Whether tapping a tag opens nem, asked fresh: the answer is a system
  /// setting and can change while nem is on screen.
  Future<TagLaunchPreference> preference();

  /// Opens the system screen where the answer can be changed.
  ///
  /// There is no way to ask again in-app. The prompt is the OS's, it is shown
  /// once ever, and this screen is the only route back from a "no".
  Future<void> showPreferenceScreen();
}
