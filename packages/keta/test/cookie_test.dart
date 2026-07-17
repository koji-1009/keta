import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;
}

Env newEnv() => Env(StdoutLog(flushInterval: Duration.zero));

Context<Env> ctxWithCookie(String? header) => testContext(
  newEnv(),
  headers: header == null ? const {} : {'cookie': header},
);

void main() {
  group('request cookies', () {
    test('parses a simple pair list', () {
      final c = ctxWithCookie('a=1; b=2');
      expect(c.cookies, {'a': '1', 'b': '2'});
      expect(c.cookie('a'), '1');
      expect(c.cookie('b'), '2');
      expect(c.cookie('missing'), isNull);
    });

    test('trims OWS around pairs, names, and values', () {
      final c = ctxWithCookie('a=1 ;  b = 2 ;c=3');
      expect(c.cookies, {'a': '1', 'b': '2', 'c': '3'});
    });

    test('skips malformed pairs without a 500', () {
      // "garbage" has no '='; "=nope" has an empty name; both are dropped.
      final c = ctxWithCookie('a=1; garbage; =nope; b=2');
      expect(c.cookies, {'a': '1', 'b': '2'});
    });

    test('first occurrence of a duplicate name wins', () {
      final c = ctxWithCookie('a=1; a=2; a=3');
      expect(c.cookie('a'), '1');
    });

    test('an empty or absent Cookie header yields no cookies', () {
      expect(ctxWithCookie('').cookies, isEmpty);
      expect(ctxWithCookie(null).cookies, isEmpty);
      expect(ctxWithCookie(null).cookie('a'), isNull);
    });

    test('splits only on the first =, keeping later = in the value', () {
      final c = ctxWithCookie('token=ab=cd==');
      expect(c.cookie('token'), 'ab=cd==');
    });

    test('values are opaque octets — nothing is decoded', () {
      final c = ctxWithCookie('x=%20%2F; y="quoted"');
      expect(c.cookie('x'), '%20%2F');
      expect(c.cookie('y'), '"quoted"');
    });

    test('the parse is cached (same map instance across calls)', () {
      final c = ctxWithCookie('a=1');
      expect(identical(c.cookies, c.cookies), isTrue);
    });
  });

  group('SetCookie rendering', () {
    test('name=value only when no attributes are set', () {
      expect(SetCookie('sid', 'abc').toHeaderValue(), 'sid=abc');
    });

    test('renders every attribute in order', () {
      final cookie = SetCookie(
        'sid',
        'abc',
        maxAge: const Duration(hours: 1),
        expires: DateTime.utc(2021, 6, 9, 10, 18, 14),
        domain: 'example.com',
        path: '/app',
        secure: true,
        httpOnly: true,
        sameSite: SameSite.lax,
      );
      expect(
        cookie.toHeaderValue(),
        'sid=abc; Max-Age=3600; Expires=Wed, 09 Jun 2021 10:18:14 GMT; '
        'Domain=example.com; Path=/app; Secure; HttpOnly; SameSite=Lax',
      );
    });

    test('expires is emitted as an IMF-fixdate in UTC', () {
      // A non-UTC input is converted; +09:00 09:00 is 00:00 UTC same day.
      final cookie = SetCookie(
        'a',
        'b',
        expires: DateTime.parse('2021-06-09T09:00:00+09:00'),
      );
      expect(
        cookie.toHeaderValue(),
        'a=b; Expires=Wed, 09 Jun 2021 00:00:00 GMT',
      );
    });

    test('SameSite tokens', () {
      expect(
        SetCookie('a', 'b', sameSite: SameSite.strict).toHeaderValue(),
        'a=b; SameSite=Strict',
      );
      expect(
        SetCookie(
          'a',
          'b',
          secure: true,
          sameSite: SameSite.none,
        ).toHeaderValue(),
        'a=b; Secure; SameSite=None',
      );
    });

    test('rides ordinary multi-value headers', () {
      final r = Response.json(
        {'ok': true},
        headers: {
          'set-cookie': [
            SetCookie('a', '1').toHeaderValue(),
            SetCookie('b', '2', httpOnly: true).toHeaderValue(),
          ],
        },
      );
      expect(r.headers['set-cookie'], ['a=1', 'b=2; HttpOnly']);
    });
  });

  group('SetCookie construction rejects injection', () {
    test('a name that is not a token', () {
      expect(() => SetCookie('', 'v'), throwsArgumentError);
      expect(() => SetCookie('a b', 'v'), throwsArgumentError);
      expect(() => SetCookie('a;b', 'v'), throwsArgumentError);
      expect(() => SetCookie('a\nb', 'v'), throwsArgumentError);
      expect(() => SetCookie('a=b', 'v'), throwsArgumentError);
    });

    test('a value carrying a header-splitting or separator octet', () {
      expect(() => SetCookie('a', 'b; Path=/evil'), throwsArgumentError);
      expect(() => SetCookie('a', 'b\r\nSet-Cookie: c=d'), throwsArgumentError);
      expect(() => SetCookie('a', 'b,c'), throwsArgumentError);
      expect(() => SetCookie('a', 'b c'), throwsArgumentError);
      expect(() => SetCookie('a', 'b\\c'), throwsArgumentError);
    });

    test('a DQUOTE-wrapped value is accepted, inner octets still checked', () {
      expect(SetCookie('a', '"ok"').toHeaderValue(), 'a="ok"');
      expect(() => SetCookie('a', '"a;b"'), throwsArgumentError);
    });

    test('domain or path carrying a control character or ";"', () {
      expect(() => SetCookie('a', 'b', domain: 'x;y'), throwsArgumentError);
      expect(() => SetCookie('a', 'b', path: '/x\r\n'), throwsArgumentError);
    });

    test('SameSite=None without Secure is rejected (RFC 6265bis)', () {
      expect(
        () => SetCookie('a', 'b', sameSite: SameSite.none),
        throwsArgumentError,
      );
      // With Secure it is fine.
      expect(
        SetCookie('a', 'b', secure: true, sameSite: SameSite.none).sameSite,
        SameSite.none,
      );
    });
  });
}
