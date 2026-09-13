import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/domain/barcode.dart';

void main() {
  group('normalising a product code', () {
    // The same physical barcode, read by the two platforms. Android's MLKit
    // reports UPC-A as the twelve digits printed under the bars; Apple's Vision
    // has no UPC-A symbology at all and reports it as an EAN-13 with a leading
    // zero. A binding matches `(kind, value)` exactly, so if these two strings
    // survive as they arrive, a box bound on one phone does not resolve on the
    // other.
    const upcA = '036000291452';
    const asEan13 = '0036000291452';

    test('a UPC-A is stored as the twelve digits printed on the box', () {
      expect(normalisedBarcode(upcA), upcA);
    });

    test('the EAN-13 form iOS reports for that same UPC-A normalises to '
        'it', () {
      expect(normalisedBarcode(asEan13), upcA);
    });

    test('so both platforms bind and resolve one value', () {
      expect(normalisedBarcode(asEan13), normalisedBarcode(upcA));
    });

    test('a genuine EAN-13 is left exactly as it was read', () {
      // GS1 reserves EAN-13 prefix 0 for UPC-A, so nothing that starts with
      // anything else can be shortened by this.
      expect(normalisedBarcode('5010358210016'), '5010358210016');
      expect(normalisedBarcode('4006381333931'), '4006381333931');
    });

    test('EAN-8 and UPC-E are left alone', () {
      // UPC-E is its own symbology on both platforms, so there is no
      // disagreement to iron out, and expanding it to UPC-A here would invent a
      // value neither reader ever produced.
      expect(normalisedBarcode('96385074'), '96385074');
      expect(normalisedBarcode('01234565'), '01234565');
    });

    test('a twelve-digit code that starts with a zero is already UPC-A', () {
      expect(normalisedBarcode('012345678905'), '012345678905');
    });

    test('a Code 128 payload is not digits, so nothing is stripped', () {
      expect(normalisedBarcode('0ABCDEFGHIJKL'), '0ABCDEFGHIJKL');
      expect(normalisedBarcode('FILTER-0012345'), 'FILTER-0012345');
    });

    test('surrounding whitespace goes, whichever branch it takes', () {
      expect(normalisedBarcode('  $asEan13 '), upcA);
      expect(normalisedBarcode('  5010358210016 '), '5010358210016');
    });

    test('an empty read stays empty rather than becoming a code', () {
      expect(normalisedBarcode('   '), '');
    });
  });
}
