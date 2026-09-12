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
