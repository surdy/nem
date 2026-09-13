# Custom URI scheme on tags, forgoing iOS background scanning

Tags carry an NDEF record of `nem://t/<uuid>`. iOS only background-launches an
app from a tag whose NDEF URI sits on a domain claimed through Universal Links,
so this choice means iPhone scanning requires nem to be open first; Android
tap-to-launch works fully via an `NDEF_DISCOVERED` intent filter on the scheme.

The alternative needed a registered domain plus hosted `apple-app-site-association`
and `assetlinks.json` files, and continued ownership of all three — recurring cost
and infrastructure to save one gesture on one of two phones.

## Consequences

iOS scanning is two gestures rather than one; an iOS Control Centre control or
Action Button shortcut can narrow that gap without changing this decision.
Reversing it means buying a domain *and* physically re-writing every tag already
stuck to something, so the cost grows the longer nem is in use.

Android's own behaviour has since moved in a way that strengthens this choice:
from Android 16, a tag carrying an `http(s)` URI fires `ACTION_VIEW` rather than
`NDEF_DISCOVERED`, and from Android 17 it surfaces an "open link" notification
requiring a tap. A domain-backed URL would therefore have lost the seamless
Android launch that was the main argument for it.

The Android launch path is nonetheless narrower than "it just works", and #9 has
to satisfy all of it:

- From Android 17 (API 37), with `targetSdk > 36`, the receiving activity must
  declare `android:permission="android.permission.DISPATCH_NFC_MESSAGE"` or it
  receives no dispatch at all. Only the NFC system service may then start that
  activity, so it must be a dedicated activity rather than the launcher — and it
  cannot be started from a test or from `adb`.
- From Android 17, an app in the stopped state (never launched by the user, or
  force-stopped) receives no NFC intents. A tag cannot be the app's first launch.
- From Android 16, the user is prompted on the app's first NFC intent and can
  permanently disallow NFC launching. Check `NfcAdapter.isTagIntentAllowed()` and
  re-prompt via `ACTION_CHANGE_TAG_INTENT_PREFERENCE`.
- `nfc_manager` does not read launch intents at all. The cold-launch path needs
  separate deep-link handling.
