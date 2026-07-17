import 'package:keta_rds/keta_rds.dart';
import 'package:test/test.dart';

void main() {
  group('requirePostgresUrl', () {
    test('accepts a postgres:// URL and returns it unchanged', () {
      const url = 'postgres://user:pass@localhost:5432/app';
      expect(requirePostgresUrl(url), url);
    });

    test('accepts the postgresql:// spelling too', () {
      const url = 'postgresql://localhost/app?sslmode=disable';
      expect(requirePostgresUrl(url), url);
    });

    test('rejects a different scheme, naming it', () {
      expect(
        () => requirePostgresUrl('mysql://localhost/app'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('mysql'),
          ),
        ),
      );
    });

    test('rejects the sqlite scheme (the sibling driver its bin handles)', () {
      expect(
        () => requirePostgresUrl('sqlite:app.db'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a bare path with no scheme', () {
      expect(
        () => requirePostgresUrl('/var/lib/app.db'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
