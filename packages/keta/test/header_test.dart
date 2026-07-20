/// The typed-header codecs: what each parses, what each refuses, and the two
/// refusal postures — a malformed value is the client's (400), while a header
/// its RFC says to ignore reads as absent rather than raising.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

Context<void> ctx(Map<String, String> headers) =>
    testContext<void>(null, headers: headers);

void main() {
  group('Authorization', () {
    test('splits scheme from credentials, lower-casing only the scheme', () {
      final c = ctx({'authorization': 'Bearer aBc.dEf'});
      final auth = c.headerAs(authorization);
      expect(auth.scheme, 'bearer');
      expect(auth.credentials, 'aBc.dEf');
      expect(auth.isScheme('BEARER'), isTrue);
      expect(auth.isScheme('basic'), isFalse);
    });

    test('a value with no scheme is a 400', () {
      final c = ctx({'authorization': 'justatoken'});
      expect(
        () => c.headerAs(authorization),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
    });

    test('absent is a 400 through headerAs and null through tryHeaderAs', () {
      final c = ctx({});
      expect(
        () => c.headerAs(authorization),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
      expect(c.tryHeaderAs(authorization), isNull);
    });

    test('round-trips through the codec', () {
      expect(authorization.write(const Authorization('bearer', 'tok')), {
        'authorization': ['bearer tok'],
      });
    });
  });

  group('Cache-Control', () {
    test('reads the directives it models and ignores the ones it does not', () {
      final c = ctx({'cache-control': 'public, max-age=60, no-transform'});
      final cc = c.headerAs(cacheControl);
      expect(cc.isPublic, isTrue);
      expect(cc.maxAge, const Duration(seconds: 60));
      // no-transform is unmodelled: dropped, not a 400 — a proxy may add its
      // own directives to a perfectly good request.
      expect(cc.noStore, isFalse);
    });

    test('a malformed delta-seconds is a 400', () {
      final c = ctx({'cache-control': 'max-age=soon'});
      expect(
        () => c.headerAs(cacheControl),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
    });

    test('writes the directives it was given, in a stable order', () {
      expect(
        cacheControl.write(
          const CacheControl(isPublic: true, maxAge: Duration(seconds: 300)),
        ),
        {
          'cache-control': ['public, max-age=300'],
        },
      );
    });
  });

  group('Accept-Encoding', () {
    test('a named coding beats the wildcard, so q=0 is a refusal', () {
      final c = ctx({'accept-encoding': 'gzip;q=0, *'});
      final enc = c.headerAs(acceptEncoding);
      expect(enc.accepts('gzip'), isFalse);
      expect(enc.qualityOf('gzip'), 0);
      expect(enc.wildcard, 1.0);
    });

    test('the wildcard applies only to codings that were not named', () {
      final c = ctx({'accept-encoding': '*'});
      expect(c.headerAs(acceptEncoding).accepts('br'), isTrue);
    });

    test('acceptsAny lets the caller own its aliases', () {
      final c = ctx({'accept-encoding': 'x-gzip'});
      final enc = c.headerAs(acceptEncoding);
      expect(enc.accepts('gzip'), isFalse);
      expect(enc.acceptsAny(const ['gzip', 'x-gzip']), isTrue);
    });

    test('an unreadable q is the default, not a 400 — the request is still '
        'well-formed', () {
      final c = ctx({'accept-encoding': 'gzip;q=high'});
      expect(c.headerAs(acceptEncoding).accepts('gzip'), isTrue);
    });
  });

  group('If-None-Match', () {
    test('* matches anything', () {
      final c = ctx({'if-none-match': '*'});
      expect(c.headerAs(ifNoneMatch).matches('anything'), isTrue);
    });

    test(
      'compares weakly: quotes and the W/ prefix are not part of the tag',
      () {
        final c = ctx({'if-none-match': 'W/"abc", "def"'});
        final condition = c.headerAs(ifNoneMatch);
        expect(condition.matches('abc'), isTrue);
        expect(condition.matches('def'), isTrue);
        expect(condition.matches('ghi'), isFalse);
      },
    );
  });

  group('Range', () {
    test('parses the three single-range forms', () {
      ByteRange parse(String value) => ctx({'range': value}).headerAs(range);
      expect(parse('bytes=0-99').resolve(1000), (0, 99));
      expect(parse('bytes=500-').resolve(1000), (500, 999));
      expect(parse('bytes=-100').resolve(1000), (900, 999));
    });

    test('clamps a last byte past the end, and refuses a start past it', () {
      ByteRange parse(String value) => ctx({'range': value}).headerAs(range);
      expect(parse('bytes=900-9999').resolve(1000), (900, 999));
      expect(parse('bytes=1000-').resolve(1000), isNull);
      expect(parse('bytes=-0').resolve(1000), isNull);
    });

    test('a suffix longer than the representation is the whole of it', () {
      expect(ctx({'range': 'bytes=-5000'}).headerAs(range).resolve(1000), (
        0,
        999,
      ));
    });

    test('an unreadable Range reads as ABSENT, not as a 400 — RFC 9110 says a '
        'server that cannot parse it must serve the whole representation', () {
      for (final value in const [
        'items=0-1',
        'bytes=abc',
        'bytes=',
        'nonsense',
      ]) {
        final c = ctx({'range': value});
        expect(c.tryHeaderAs(range), isNull, reason: value);
        // Even the required accessor reports it as missing rather than
        // malformed: there is no posture in which an ignorable header is the
        // caller's fault.
        expect(
          () => c.headerAs(range),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
          reason: value,
        );
      }
    });
  });

  group('Set-Cookie', () {
    test('renders through the same accessor everything else uses', () {
      expect(
        setCookies.write([
          SetCookie('sid', 'abc', httpOnly: true),
          SetCookie('theme', 'dark'),
        ]),
        {
          'set-cookie': ['sid=abc; HttpOnly', 'theme=dark'],
        },
      );
    });
  });

  test('an application can declare its own accessor', () {
    const traceCount = HeaderAccessor<int>(
      'x-trace-count',
      HeaderCodec(decode: _decodeCount, encode: _encodeCount),
    );
    expect(ctx({'x-trace-count': '3'}).headerAs(traceCount), 3);
    expect(
      () => ctx({'x-trace-count': 'many'}).headerAs(traceCount),
      throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
    );
    expect(traceCount.write(7), {
      'x-trace-count': ['7'],
    });
  });
}

int _decodeCount(List<String> values) =>
    int.tryParse(values.first) ??
    (throw const BadRequest('x-trace-count must be an integer'));

List<String> _encodeCount(int value) => ['$value'];
