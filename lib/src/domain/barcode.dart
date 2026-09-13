// Product codes — the codes nem binds but did not create (CONTEXT.md —
// "Barcode").

/// Digits and nothing else.
final _digits = RegExp(r'^[0-9]+$');

/// The value a binding stores for a scanned product code, whichever phone read
/// it.
///
/// UPC-A is the only symbology that needs canonicalising, and it needs it
/// because the two platforms disagree about what a UPC-A is:
///
///  * Android's MLKit maps UPC-A natively and reports the twelve digits printed
///    under the bars.
///  * Apple's Vision framework has no UPC-A symbology at all — in
///    `mobile_scanner`'s Swift bridge the format falls through to nil, so a
///    scanner restricted to UPC-A detects nothing on an iPhone, silently and
///    with no error. Vision reports UPC-A codes as EAN-13 instead: the same
///    twelve digits behind a leading zero.
///
/// Asking for EAN-13 alongside UPC-A is what makes the code *detectable* on
/// both (see `scanFormats`). This is the other half, and it is a correctness
/// problem rather than a detection one: a binding matches on `(kind, value)`
/// exactly, so without a canonical form a filter box bound on an Android phone
/// would not resolve on an iPhone, and one bound on an iPhone would not resolve
/// on Android.
///
/// The canonical form is the twelve-digit UPC-A, so a thirteen-digit code with
/// a leading zero loses it. That prefix is not ambiguous: GS1 reserves EAN-13
/// prefix 0 for UPC-A, so every thirteen-digit code starting with one is a
/// UPC-A wearing an EAN-13 coat and no genuine EAN-13 is shortened by this.
///
/// Everything else — EAN-8, EAN-13 proper, UPC-E, Code 128 — comes back trimmed
/// and otherwise exactly as it was read. In particular UPC-E is left alone:
/// both platforms report it as its own symbology, so there is no disagreement
/// to iron out, and expanding it to UPC-A here would invent a value neither
/// reader ever produced.
String normalisedBarcode(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length == 13 &&
      trimmed.startsWith('0') &&
      _digits.hasMatch(trimmed)) {
    return trimmed.substring(1);
  }
  return trimmed;
}
