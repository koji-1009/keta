/// The pattern this file exists to prove: a token/session is revoked → a
/// revocation notice is published on the bus → the server closes the
/// affected live connection FROM ITS OWN SIDE. `/logout` is the revocation
/// trigger (lib/auth.dart's `logout`); `/me/events` is the live connection
/// (lib/auth.dart's `sessionEvents`). This is a demonstrated app-code
/// pattern, not a keta mechanism — see lib/auth.dart's doc on `sessionEvents`
/// for why it is built on an explicit `StreamController` rather than an
/// `async*` generator (a real cancellation-leak the generator shape had, not
/// just a style choice).
library;

import 'dart:async';
import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_auth_example/app.dart';
import 'package:keta_auth_example/auth.dart';
import 'package:keta_auth_example/env.dart';
import 'package:keta_bus/keta_bus.dart';
import 'package:test/test.dart';

/// A minimal [TransportRequest] so a test can drive the app pipeline directly
/// and hold onto a streaming [Response] instead of draining it — the same
/// shape `../register`'s test/streaming_test.dart uses for its SSE feed,
/// since `TestClient` has no dedicated SSE helper and would hang forever
/// draining an open one.
class _Req implements TransportRequest {
  _Req(this.method, String path, {Map<String, String> headers = const {}})
    : uri = Uri.parse(path),
      headers = {
        for (final e in headers.entries) e.key.toLowerCase(): [e.value],
      };
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final Map<String, List<String>> headers;
  @override
  Stream<List<int>> get bodyStream => const Stream.empty();
  @override
  String get remoteAddress => 'test';
  @override
  Future<void> get closed => Completer<void>().future;
}

Future<Env> boot() async => Env(StdoutLog(flushInterval: Duration.zero));

void main() {
  test('logout revokes the session, and the open /me/events stream for that '
      'session ends itself right after — a server-initiated close', () async {
    final env = await boot();
    addTearDown(env.close);
    final app = buildApp();
    final router = app.compile(env);
    final client = TestClient(app, env);

    final login = await client.post(
      '/login',
      json: {'username': 'admin', 'password': 'admin-pass'},
    );
    expect(login.status, 200);
    final sid = RegExp(
      r'sid=([^;]+)',
    ).firstMatch(login.headers['set-cookie']!)!.group(1)!;
    final cookieHeader = {'cookie': 'sid=$sid'};

    // Open the feed and hold its raw body stream — draining it via
    // TestClient would hang forever on an SSE connection nothing has ended
    // yet.
    final streamResponse = await router.dispatch(
      _Req('GET', '/me/events', headers: cookieHeader),
    );
    expect(streamResponse.status, 200);
    expect(streamResponse.headers['content-type'], [
      'text/event-stream; charset=utf-8',
    ]);
    final chunks = <List<int>>[];
    var done = false;
    final sub = (streamResponse.body as Stream<List<int>>).listen(
      chunks.add,
      onDone: () => done = true,
    );
    addTearDown(sub.cancel);

    // Not yet revoked: nothing has arrived, and the stream is still open.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse);
    expect(chunks, isEmpty);

    // The trigger: /logout revokes this exact session.
    final out = await client.post('/logout', headers: cookieHeader);
    expect(out.status, 200);

    // The proof: the feed received the revocation event AND the underlying
    // response stream is done — not "the client happened to stop reading",
    // the source genuinely ended (sessionEvents' generator returned).
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(done, isTrue, reason: 'the stream must end itself on revocation');
    final wire = utf8.decode(chunks.expand((c) => c).toList());
    expect(wire, contains('event: revoked'));

    // The revoked session cannot be used for anything else either — the
    // ordinary auth consequence of revocation, alongside the stream close.
    expect((await client.get('/me', headers: cookieHeader)).status, 401);
  });

  test('a session that is never revoked keeps its feed open — the close is '
      'conditional on revocation, not a fixed lifetime', () async {
    final env = await boot();
    addTearDown(env.close);
    final app = buildApp();
    final router = app.compile(env);
    final client = TestClient(app, env);

    final login = await client.post(
      '/login',
      json: {'username': 'member', 'password': 'member-pass'},
    );
    final sid = RegExp(
      r'sid=([^;]+)',
    ).firstMatch(login.headers['set-cookie']!)!.group(1)!;

    final streamResponse = await router.dispatch(
      _Req('GET', '/me/events', headers: {'cookie': 'sid=$sid'}),
    );
    var done = false;
    final sub = (streamResponse.body as Stream<List<int>>).listen(
      (_) {},
      onDone: () => done = true,
    );
    // Cancelling promptly (not left to time out) is itself a claim worth
    // pinning: sessionEvents used to be built on async*/`await for`, which
    // does not respond to its subscription being cancelled while parked mid-
    // `await for` — see lib/auth.dart's sessionEvents doc. A regression back
    // to that shape would hang this teardown until the suite's own timeout.
    addTearDown(sub.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(done, isFalse);
  });

  test(
    'an anonymous /me/events request is 401 before any stream opens',
    () async {
      final env = await boot();
      addTearDown(env.close);
      expect((await TestClient(buildApp(), env).get('/me/events')).status, 401);
    },
  );

  test('cancelling sessionEvents before revocation completes promptly — '
      'the StreamController shape, not an async* generator parked in '
      'await for, is what makes a client disconnect release the bus '
      'subscription instead of leaking it', () async {
    final bus = InMemoryBus();
    addTearDown(bus.close);
    final sub = sessionEvents(bus, 'sid-never-revoked').listen((_) {});
    // A generous but FINITE timeout: this must resolve well under it. The
    // bug this pins reproduced as a hang past 30s (package:test's default
    // timeout) with no error at all — asserting a short timeout here turns
    // a regression into a fast, loud failure instead of a mysteriously
    // stuck suite.
    await sub.cancel().timeout(const Duration(seconds: 2));
  });
}
