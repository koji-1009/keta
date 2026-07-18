import 'dart:typed_data';

import 'package:keta_rds/src/values.dart';
import 'package:postgres/postgres.dart' show Type;
import 'package:test/test.dart';

/// Unit coverage for the §3 type-mapping layer, exercised directly against
/// [mapValue] so the temporal-rendering rules are pinned without a live server
/// (the live path is covered too — see the contract suite's "each storage class
/// maps to its contracted Dart type" and the timestamp/date cases there).
///
/// The three temporal shapes are the point: the driver decodes `date`,
/// `timestamp`, and `timestamptz` all to `DateTime.utc(...)`, so only the
/// column [Type] tells them apart, and each renders differently on purpose.
void main() {
  group('temporal rendering keys off the column type', () {
    // The driver hands every temporal value back UTC-tagged, so all three cases
    // start from the same DateTime.utc — the divergence is entirely the rule's.
    final instant = DateTime.utc(2026, 7, 17, 10, 30, 15, 123);

    test('timestamptz is emitted as UTC with a Z (a real instant)', () {
      expect(mapValue(instant, Type.timestampTz), '2026-07-17T10:30:15.123Z');
    });

    test('timestamp (no tz) is emitted WITHOUT an offset designator', () {
      // No trailing Z / +00:00: the column carries no zone, so the string must
      // not assert one. The wall-clock reading is preserved exactly.
      final mapped = mapValue(instant, Type.timestampWithoutTimezone);
      expect(mapped, '2026-07-17T10:30:15.123');
      expect(mapped, isNot(endsWith('Z')));
    });

    test('date is emitted as yyyy-MM-dd, not a full datetime', () {
      // A date column decodes to midnight-UTC; the old toIso8601String() leaked
      // that as '2026-07-17T00:00:00.000Z'. Only the calendar day survives.
      expect(mapValue(DateTime.utc(2026, 7, 17), Type.date), '2026-07-17');
    });

    test('date zero-pads month and day', () {
      expect(mapValue(DateTime.utc(2026, 1, 5), Type.date), '2026-01-05');
    });

    test('date renders a BC year as a signed 4-digit ISO 8601 year', () {
      // Regression: hand-padding `year.toString().padLeft(4, '0')` produces
      // '0-44-03-15' for year -44 (padLeft counts the leading '-' as a digit),
      // which is not valid ISO 8601 and does not round-trip.
      expect(mapValue(DateTime.utc(-44, 3, 15), Type.date), '-0044-03-15');
    });

    test('date renders a >9999 year with the required leading +', () {
      // Regression: hand-padding leaves a bare '12345-01-02' with no sign,
      // which ISO 8601 requires once the year exceeds 4 digits.
      expect(mapValue(DateTime.utc(12345, 1, 2), Type.date), '+012345-01-02');
    });

    test('timestamptz still round-trips through DateTime.parse to the same '
        'UTC instant', () {
      final mapped = mapValue(instant, Type.timestampTz) as String;
      expect(DateTime.parse(mapped), instant);
    });
  });

  group('non-temporal values pass the contract through', () {
    test('bytea becomes a fixed-length List<int> that rejects mutation', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final mapped = mapValue(bytes, Type.byteArray);
      expect(mapped, isA<List<int>>());
      expect(mapped, [1, 2, 3]);
      expect(() => (mapped as List<int>).add(4), throwsUnsupportedError);
    });

    test('a String (e.g. a numeric decimal) passes through unchanged', () {
      expect(mapValue('12.34', Type.numeric), '12.34');
    });

    test('int, double, bool, and null pass through unchanged', () {
      expect(mapValue(7, Type.integer), 7);
      expect(mapValue(1.5, Type.double), 1.5);
      expect(mapValue(true, Type.boolean), true);
      expect(mapValue(null, Type.text), isNull);
    });
  });
}
