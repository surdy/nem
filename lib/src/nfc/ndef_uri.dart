import 'dart:convert';
import 'dart:typed_data';

// `ndef_record` is pure Dart — no method channel, no plugin — and nfc_manager
// re-exports it precisely so a caller can build messages without importing a
// package it does not depend on. Everything in this file therefore runs in a
// plain unit test.
import 'package:nfc_manager/ndef_record.dart';

/// The record type byte of an NFC Forum URI record: `'U'`.
const _uriRecordType = 0x55;

/// The record type byte of an NFC Forum Text record: `'T'`.
const _textRecordType = 0x54;

/// The NFC Forum URI Record Type Definition's abbreviation table.
///
/// A URI record's first payload byte is an index into this list, and the rest
/// of the payload is UTF-8 for whatever the prefix does not cover. Index 0 is
/// "no prefix", which is the only one a custom scheme like `nem://` can use —
/// there is no entry for it and never will be (ADR 0009).
const _uriPrefixes = <String>[
  '', // 0x00 — no abbreviation. What nem writes.
  'http://www.',
  'https://www.',
  'http://',
  'https://',
  'tel:',
  'mailto:',
  'ftp://anonymous:anonymous@',
  'ftp://ftp.',
  'ftps://',
  'sftp://',
  'smb://',
  'nfs://',
  'ftp://',
  'dav://',
  'news:',
  'telnet://',
  'imap:',
  'rtsp://',
  'urn:',
  'pop:',
  'sip:',
  'sips:',
  'tftp:',
  'btspp://',
  'btl2cap://',
  'btgoep://',
  'tcpobex://',
  'irdaobex://',
  'file://',
  'urn:epc:id:',
  'urn:epc:tag:',
  'urn:epc:pat:',
  'urn:epc:raw:',
  'urn:epc:',
  'urn:nfc:',
];

/// The NDEF message nem writes to a tag: one well-known URI record carrying
/// [uri] (ADR 0009).
///
/// Assembled by hand because there is no helper to assemble it with:
/// `NdefRecord.createUri` existed in `nfc_manager` 3.x and did not survive the
/// move of NDEF into `nfc_manager_ndef`. The leading `0x00` is the abbreviation
/// index meaning "no prefix" — mandatory, and the byte most easily forgotten,
/// since leaving it off produces a record that parses as a URI beginning with
/// whatever `nem://…`'s first character abbreviates to.
NdefMessage ndefUriMessage(String uri) => NdefMessage(
  records: [
    NdefRecord(
      typeNameFormat: TypeNameFormat.wellKnown,
      type: Uint8List.fromList([_uriRecordType]),
      identifier: Uint8List(0),
      payload: Uint8List.fromList([0x00, ...utf8.encode(uri)]),
    ),
  ],
);

/// The URI [message] carries, or null when it carries none.
///
/// The first record that yields one wins. Null is an ordinary answer rather
/// than an error: a tag somebody else wrote may hold a text record, a vCard or
/// an app record, and none of those is a code nem can resolve.
String? uriFromNdefMessage(NdefMessage? message) {
  if (message == null) return null;
  for (final record in message.records) {
    final uri = uriFromNdefRecord(record);
    if (uri != null && uri.isNotEmpty) return uri;
  }
  return null;
}

/// The URI or text [record] carries, or null.
///
/// Three shapes are understood, and the two that are not nem's own are
/// understood on purpose: a third-party tag with a payload of its own is still
/// a code that can be bound to a target, so reading it as a string is what lets
/// the scan flow offer to bind it rather than call the tag broken.
String? uriFromNdefRecord(NdefRecord record) {
  final payload = record.payload;

  // An absolute-URI record stores the URI raw, with no abbreviation byte.
  if (record.typeNameFormat == TypeNameFormat.absoluteUri) {
    return _utf8OrNull(payload);
  }

  if (record.typeNameFormat != TypeNameFormat.wellKnown ||
      record.type.length != 1) {
    return null;
  }

  switch (record.type.single) {
    case _uriRecordType:
      if (payload.isEmpty) return null;
      final prefix = payload.first < _uriPrefixes.length
          ? _uriPrefixes[payload.first]
          : '';
      final rest = _utf8OrNull(payload.sublist(1));
      return rest == null ? null : '$prefix$rest';
    case _textRecordType:
      // Status byte: the low six bits are the length of the IANA language code
      // that follows it, and the text is everything after that.
      if (payload.isEmpty) return null;
      final languageLength = payload.first & 0x3f;
      if (payload.length < 1 + languageLength) return null;
      return _utf8OrNull(payload.sublist(1 + languageLength));
    default:
      return null;
  }
}

/// [bytes] as UTF-8, or null when they are not UTF-8 at all.
String? _utf8OrNull(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}
