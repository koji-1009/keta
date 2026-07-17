import 'package:keta/keta.dart';
import 'package:test/test.dart';

/// A canonical, fully valid W3C traceparent used as the baseline the rejection
/// cases each mutate exactly one field of.
const _valid = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';

void main() {
  group('TraceContext.parse', () {
    test('accepts a canonical valid traceparent and exposes its fields', () {
      final trace = TraceContext.parse(_valid);
      expect(trace, isNotNull);
      expect(trace!.traceId, '0af7651916cd43dd8448eb211c80319c');
      expect(trace.parentId, 'b7ad6b7169203331');
      // Flags `01` = the sampled bit; parsed as an 8-bit octet, not int-coerced.
      expect(trace.flags, 0x01);
    });

    test('accepts flags with the sampled bit clear (00)', () {
      final trace = TraceContext.parse(
        '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00',
      );
      expect(trace, isNotNull);
      expect(trace!.flags, 0x00);
    });

    // Each entry mutates exactly one field of [_valid] into a spec violation;
    // the rejection is total (null), never a partial parse.
    final rejections = <String, String>{
      'not four dash-parts': 'garbage',
      'too many parts': '$_valid-extra',
      'traceId too short': '00-abc-b7ad6b7169203331-01',
      'parentId too short': '00-0af7651916cd43dd8448eb211c80319c-b7ad-01',
      'non-hex traceId (32 g\'s)':
          '00-gggggggggggggggggggggggggggggggg-b7ad6b7169203331-01',
      'non-hex parentId': '00-0af7651916cd43dd8448eb211c80319c-gggggggggggggggg-01',
      'uppercase traceId':
          '00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01',
      'uppercase parentId':
          '00-0af7651916cd43dd8448eb211c80319c-B7AD6B7169203331-01',
      'all-zero traceId':
          '00-00000000000000000000000000000000-b7ad6b7169203331-01',
      'all-zero parentId':
          '00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01',
      'reserved version ff':
          'ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
      'non-hex version':
          'gg-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
      'single-char version':
          '0-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
      // int.tryParse(radix: 16) would admit each of these one-off flags forms
      // ('1' -> 1, '+a' -> 10); a valid flags octet is exactly two hex digits.
      'single-digit flags':
          '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-1',
      'signed flags':
          '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-+a',
      'three-digit flags':
          '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-001',
      'non-hex flags':
          '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-zz',
    };
    rejections.forEach((why, header) {
      test('rejects $why', () {
        expect(TraceContext.parse(header), isNull, reason: header);
      });
    });
  });
}
