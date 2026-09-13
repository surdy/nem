import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/binding.dart';
import 'package:nem/src/nfc/ndef_uri.dart';
import 'package:nfc_manager/ndef_record.dart';

/// A record built the way a tag written by somebody else would be.
NdefRecord record({
  required TypeNameFormat typeNameFormat,
  List<int> type = const [],
  List<int> payload = const [],
}) => NdefRecord(
  typeNameFormat: typeNameFormat,
  type: Uint8List.fromList(type),
  identifier: Uint8List(0),
  payload: Uint8List.fromList(payload),
);

void main() {
  const uri = 'nem://t/2a1f7c58-8c2e-4a3b-9f10-0a1b2c3d4e5f';

  group('writing', () {
    test('is one well-known URI record', () {
      final message = ndefUriMessage(uri);
      expect(message.records.length, 1);
      final only = message.records.single;
      expect(only.typeNameFormat, TypeNameFormat.wellKnown);
      // 'U', which is what makes it a URI record rather than text.
      expect(only.type, [0x55]);
      expect(only.identifier, isEmpty);
    });

    test('begins with the no-prefix byte, because nem:// abbreviates to '
        'nothing', () {
      final payload = ndefUriMessage(uri).records.single.payload;
      // 0x00 is "no abbreviation". Leaving it off would not produce a broken
      // record — it would produce a record claiming the URI starts with
      // whatever 'n' happens to index, which is far worse.
      expect(payload.first, 0x00);
      expect(payload.sublist(1), utf8.encode(uri));
    });

    test('round-trips', () {
      expect(uriFromNdefMessage(ndefUriMessage(uri)), uri);
    });

    test('fits a tag with any room at all, which is why capacity has to be '
        'checked against the real number', () {
      // The whole message for a nem URI: header, type, and the URI itself.
      // Comfortably inside an NTAG213's 144 bytes, let alone a 215 or a 216 —
      // but a 48-byte NTAG210 or a tag already holding something else is not a
      // hypothetical, which is what the pre-check in `refuseWrite` is for.
      expect(ndefUriMessage(uri).byteLength, lessThan(60));
      expect(ndefUriMessage(uri).byteLength, greaterThan(uri.length));
    });

    test('writes the URI a label encodes, byte for byte', () {
      // ADR 0009: the tag and the printed label carry the same string, which is
      // exactly why the resolver cannot tell them apart and the carrier has to
      // be passed in.
      const targetId = '2a1f7c58-8c2e-4a3b-9f10-0a1b2c3d4e5f';
      expect(uriFromNdefMessage(ndefUriMessage(labelUriFor(targetId))), uri);
    });
  });

  group('reading', () {
    test('expands an abbreviated prefix, so a tag somebody else wrote reads '
        'as the URL it shows', () {
      final https = record(
        typeNameFormat: TypeNameFormat.wellKnown,
        type: [0x55],
        payload: [0x04, ...utf8.encode('example.com/filter')],
      );
      expect(uriFromNdefRecord(https), 'https://example.com/filter');
    });

    test('reads an absolute-URI record, which carries no prefix byte', () {
      final absolute = record(
        typeNameFormat: TypeNameFormat.absoluteUri,
        payload: utf8.encode('https://example.com/x'),
      );
      expect(uriFromNdefRecord(absolute), 'https://example.com/x');
    });

    test('reads a text record past its language code', () {
      // Status byte 0x02: UTF-8, and a two-character language code.
      final text = record(
        typeNameFormat: TypeNameFormat.wellKnown,
        type: [0x54],
        payload: [0x02, ...utf8.encode('en'), ...utf8.encode('boiler filter')],
      );
      expect(uriFromNdefRecord(text), 'boiler filter');
    });

    test('an unknown prefix index falls back to no prefix rather than '
        'throwing', () {
      final odd = record(
        typeNameFormat: TypeNameFormat.wellKnown,
        type: [0x55],
        payload: [0x7f, ...utf8.encode('weird')],
      );
      expect(uriFromNdefRecord(odd), 'weird');
    });

    test('a record of a type nem does not read is null, not an error', () {
      final media = record(
        typeNameFormat: TypeNameFormat.media,
        type: utf8.encode('text/vcard'),
        payload: utf8.encode('BEGIN:VCARD'),
      );
      expect(uriFromNdefRecord(media), isNull);
    });

    test('the first record that yields something wins', () {
      final message = NdefMessage(
        records: [
          record(
            typeNameFormat: TypeNameFormat.media,
            type: utf8.encode('text/vcard'),
            payload: utf8.encode('BEGIN:VCARD'),
          ),
          ndefUriMessage(uri).records.single,
        ],
      );
      expect(uriFromNdefMessage(message), uri);
    });

    test('an empty message, and no message at all, are both null', () {
      expect(uriFromNdefMessage(const NdefMessage(records: [])), isNull);
      expect(uriFromNdefMessage(null), isNull);
    });

    test('a truncated payload is null rather than a crash', () {
      expect(
        uriFromNdefRecord(
          record(typeNameFormat: TypeNameFormat.wellKnown, type: [0x55]),
        ),
        isNull,
      );
    });
  });
}
