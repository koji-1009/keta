/// Owns Context's request-scoped API: the identity-keyed per-request store,
/// c.param typed coercion (double/bool) with 400s on bad input and
/// ArgumentErrors on misuse, and the transport `closed` -> c.aborted wiring.
@TestOn('vm')
library;

import 'dart:async';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// A request whose connection close can be triggered, to exercise the
/// transport `closed` → `ctx.abort()` wiring.
class _CloseableRequest implements TransportRequest {
  _CloseableRequest(this.method, this.uri, this.headers);
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final Map<String, List<String>> headers;
  @override
  final String remoteAddress = 'test';
  final Completer<void> _closed = Completer<void>();

  @override
  Stream<List<int>> get bodyStream => const Stream.empty();
  @override
  Future<void> get closed => _closed.future;
  void disconnect() => _closed.complete();
}

/// A request whose `remoteAddress` counts every resolve and returns a value that
/// *changes* per call, so a test can prove dispatch never eagerly resolves it and
/// that a handler reading it twice caches the first value.
class _CountingRemoteRequest implements TransportRequest {
  _CountingRemoteRequest(this.method, this.uri, this.headers);
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final Map<String, List<String>> headers;
  int reads = 0;
  @override
  String get remoteAddress {
    reads++;
    return 'ip-$reads';
  }

  @override
  Stream<List<int>> get bodyStream => const Stream.empty();
  @override
  Future<void> get closed => Completer<void>().future;
}

void main() {
  group('per-request store', () {
    test('get/set/tryGet with identity-compared keys', () {
      final c = testContext(newEnv());
      final k = Key<int>('n');
      expect(() => c.get(k), throwsStateError);
      expect(c.tryGet(k), isNull);
      c.set(k, 7);
      expect(c.get(k), 7);

      // A bound null is "present", distinct from unset.
      final kn = Key<int?>('maybe');
      c.set(kn, null);
      expect(c.get(kn), isNull);

      // Keys compare by identity: a same-named new key is a different key.
      expect(() => c.get(Key<int>('n')), throwsStateError);
    });
  });

  group('c.param typing', () {
    test('parses double and bool, rejecting bad input with 400', () {
      final c = testContext(
        newEnv(),
        params: {'d': '2.5', 't': 'true', 'f': 'false', 'bad': 'TRUE'},
      );
      expect(c.param<double>('d'), 2.5);
      expect(c.param<bool>('t'), isTrue);
      expect(c.param<bool>('f'), isFalse);
      expect(
        () => c.param<bool>('bad'),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
      expect(() => c.param<double>('bad'), throwsA(isA<KetaException>()));
    });

    test('an unknown name or unsupported type is an ArgumentError', () {
      final c = testContext(newEnv(), params: {'id': 'x'});
      expect(() => c.param<String>('nope'), throwsArgumentError);
      expect(() => c.param<Duration>('id'), throwsArgumentError);
    });
  });

  group('c.remoteAddress is lazy and cached', () {
    test('a handler that never reads it never resolves it', () async {
      final app = App<Env>();
      app.get('/x', (c) => c.text('ok'));
      final router = app.compile(newEnv());

      final req = _CountingRemoteRequest('GET', Uri.parse('/x'), const {});
      final response = await router.dispatch(req);

      expect(response.status, 200);
      // Dispatch no longer eagerly reads the peer address — the whole point of
      // the laziness: a handler that never touches it pays nothing.
      expect(req.reads, 0);
    });

    test(
      'reading it twice resolves once and returns a consistent value',
      () async {
        final app = App<Env>();
        late String first;
        late String second;
        app.get('/x', (c) {
          first = c.remoteAddress;
          second = c.remoteAddress;
          return c.text('ok');
        });
        final router = app.compile(newEnv());

        final req = _CountingRemoteRequest('GET', Uri.parse('/x'), const {});
        await router.dispatch(req);

        // Cached after the first resolve: both reads see 'ip-1', not the changing
        // 'ip-2' a re-resolve would produce, and the source was touched once.
        expect(first, 'ip-1');
        expect(second, 'ip-1');
        expect(req.reads, 1);
      },
    );
  });

  test('a transport disconnect (closed) fires c.aborted', () async {
    final app = App<Env>();
    final sawAbort = Completer<void>();
    app.get('/x', (c) {
      unawaited(c.aborted.then((_) => sawAbort.complete()));
      return Completer<Response>().future; // hang until cancelled
    });
    final router = app.compile(newEnv());

    final req = _CloseableRequest('GET', Uri.parse('/x'), const {});
    unawaited(Future.sync(() => router.dispatch(req))); // fire; it hangs
    await Future<void>.delayed(Duration.zero);
    req.disconnect(); // the client drops the connection

    await sawAbort.future.timeout(const Duration(seconds: 1));
  });
}
