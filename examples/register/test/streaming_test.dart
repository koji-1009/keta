/// The SSE feed: create/update/delete events flow to an open in-process
/// subscriber, gated by the same security as everything else. See
/// openapi_test.dart for the doc-conformance half (the feed's content type
/// and per-event schema).
library;

import 'dart:async';
import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_register_example/app.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A minimal [TransportRequest] so a test can drive the app pipeline directly
/// and hold onto a streaming [Response] instead of draining it — which is what
/// TestClient.get does, and what would hang forever on an open SSE feed.
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
  // The in-process request never disconnects on its own.
  @override
  Future<void> get closed => Completer<void>().future;
}

void main() {
  test('the SSE feed streams create/update/delete as named events', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    // One app instance so the write handlers and the feed share the same
    // Env-owned event bus (see lib/env.dart's Env.bus); drive the feed through
    // the pipeline (holding the open stream), and the writes through an
    // ordinary client on the same app.
    final app = buildApp();
    final router = app.compile(env);
    final client = TestClient(app, env);

    // The gate runs before the stream opens: an anonymous subscriber is 401,
    // never a socket that then has to be torn down.
    final anon = await router.dispatch(_Req('GET', '/users/events'));
    expect(anon.status, 401);

    final response = await router.dispatch(
      _Req('GET', '/users/events', headers: admin),
    );
    expect(response.status, 200);
    expect(response.headers['content-type'], [
      'text/event-stream; charset=utf-8',
    ]);
    final chunks = <List<int>>[];
    final sub = (response.body as Stream<List<int>>).listen(chunks.add);

    await client.post(
      '/users',
      headers: admin,
      json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
    );
    await client.put(
      '/users/1',
      headers: admin,
      json: {'id': '1', 'name': 'Ada B', 'role': 'member', 'tags': <String>[]},
    );
    await client.delete('/users/1', headers: admin);
    // A tick for the broadcast to fan the three events into the body stream.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    final wire = utf8.decode(chunks.expand((c) => c).toList());
    expect(wire, contains('event: created'));
    expect(wire, contains('event: updated'));
    expect(wire, contains('event: deleted'));
    expect(wire, contains('"id":"1"'));
  });
}
