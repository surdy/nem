import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/binding.dart';
import 'package:nem/src/nfc/ndef_uri.dart';
import 'package:nem/src/nfc/tag_gateway.dart';

void main() {
  final message = ndefUriMessage(
    labelUriFor('2a1f7c58-8c2e-4a3b-9f10-0a1b2c3d4e5f'),
  );

  group('refusing a write before making it', () {
    test('a tag with room takes it', () {
      expect(
        refuseWrite(
          isWritable: true,
          // An NTAG215's usable NDEF area.
          capacity: 504,
          messageSize: message.byteLength,
        ),
        isNull,
      );
    });

    test('a tag without room is refused, and says by how much', () {
      // The criterion this whole pre-check exists for: "insufficient capacity"
      // is a distinct outcome, and it can only be distinct here. Android
      // reports an over-capacity write, a tag pulled away and an RF glitch as
      // the same bare IOException, so nothing downstream of `write` could ever
      // tell them apart.
      final outcome = refuseWrite(
        isWritable: true,
        // An NTAG203's 48 bytes, already mostly spoken for.
        capacity: 12,
        messageSize: message.byteLength,
      );
      expect(outcome, isA<TagTooSmall>());
      expect((outcome! as TagTooSmall).capacity, 12);
      expect((outcome as TagTooSmall).needed, message.byteLength);
    });

    test('a message exactly the size of the tag fits', () {
      expect(
        refuseWrite(isWritable: true, capacity: 40, messageSize: 40),
        isNull,
      );
    });

    test('a locked tag is refused whatever its size', () {
      expect(
        refuseWrite(isWritable: false, capacity: 504, messageSize: 40),
        isA<TagReadOnly>(),
      );
    });

    test('a locked tag reads as locked rather than as too small, so the '
        'advice is "use a blank one" and not "use a bigger one"', () {
      expect(
        refuseWrite(isWritable: false, capacity: 0, messageSize: 40),
        isA<TagReadOnly>(),
      );
    });
  });
}
