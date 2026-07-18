library;

import 'dart:async';
import 'dart:io' show HttpConnectionInfo;

import 'package:keta/keta.dart';
import 'package:shelf/shelf.dart' as shelf;

/// Mounts a keta [app] as a shelf handler: it compiles the app once (so route
/// conflicts fail fast here) and runs the full keta pipeline per request. Use
/// it to serve keta from an existing shelf stack.
///
/// A route that answers with `Response.upgrade` (WebSocket) cannot be served
/// this way — shelf hands no socket across this bridge — so such a response is
/// rejected with a `StateError` rather than mis-framed onto the wire.
///
/// Client disconnect is invisible through this bridge: shelf exposes no
/// connection-close signal (see `_ShelfRequest.closed`), so `c.aborted`,
/// `timeout()`'s cooperative-cancellation abort, and any SSE/WebSocket-style
/// cleanup that watches for the client leaving never fire — a keta route doing
/// long-poll or SSE work runs to completion (or its own timeout) even after the
/// peer is long gone. The bundled H1 transport, by contrast, can observe a drop
/// mid-request. A keta app relying on disconnect detection should be served on
/// its own transport, not mounted here.
shelf.Handler ketaToShelf<E>(App<E> app, E env, {int maxBodyBytes = 1 << 20}) {
  final router = app.compile(env, maxBodyBytes: maxBodyBytes);
  return (shelf.Request request) async {
    // keta handlers read the body through Context, which enforces maxBodyBytes
    // at its buffering point; bodyStream() stays the deliberate escape.
    final response = await router.dispatch(_ShelfRequest(request));
    // A `Response.upgrade` cannot be honored here: switching protocols needs the
    // raw socket, and this bridge deliberately exposes none (mirroring that
    // `shelf.Request.hijack` is unsupported the other way). Fail loudly and
    // predictably rather than silently answering 101 with an empty body that no
    // client could use — an upgrade route simply cannot be served through shelf.
    if (response.upgrade != null) {
      throw StateError(
        'keta Response.upgrade (WebSocket) reached the shelf bridge, which '
        'cannot switch protocols — serve upgrade routes on keta\'s own '
        'transport (H1Transport), not through ketaToShelf',
      );
    }
    // Drop framing headers keta may have set: the body is re-framed by shelf /
    // the server, and a stale content-length on a stream body corrupts the wire.
    final headers = {
      ...response.headers,
    }..removeWhere((k, _) => k == 'content-length' || k == 'transfer-encoding');
    return shelf.Response(
      response.status,
      body: response.body,
      headers: headers,
    );
  };
}

/// Adapts a shelf [handler] into a keta terminal [Handler], so shelf handlers
/// and middleware can run inside a keta route.
///
/// Request and response bodies are streamed through unbuffered, so large
/// uploads and long-lived responses (SSE, chunked) work. The request stream
/// handed to the shelf handler is wrapped in a counting limiter that enforces
/// [maxBodyBytes] as a [PayloadTooLarge] stream error (set it to the app's
/// `maxBodyBytes`). Websocket hijack is not supported — keta's [Transport]
/// exposes no socket — and a `request.hijack()` surfaces as a `StateError`.
///
/// The synthesized `shelf.Request` carries no `context` map: keta has nothing
/// to put there (no `shelf.io.connection_info` and friends), so shelf
/// middleware that reads `shelf_io`-specific context keys degrades to its
/// fallback behavior instead of throwing.
Handler<E> shelfToKeta<E>(shelf.Handler handler, {int maxBodyBytes = 1 << 20}) {
  return (Context<E> c) async {
    final request = shelf.Request(
      c.method,
      _absolute(c.uri, c.header('host')),
      headers: c.headers,
      body: _limited(c.bodyStream(), maxBodyBytes),
    );
    final response = await handler(request);
    // Pass the response body straight through as a stream; strip framing so the
    // transport frames it (a case-mismatched Content-Length would otherwise slip
    // through and corrupt the wire). headersAll keeps multi-value headers (e.g.
    // several set-cookie) faithful across the bridge.
    final headers = {...response.headersAll}
      ..removeWhere(
        (k, _) =>
            k.toLowerCase() == 'content-length' ||
            k.toLowerCase() == 'transfer-encoding',
      );
    return Response(
      response.statusCode,
      headers: headers,
      body: response.read(),
    );
  };
}

/// shelf requires an absolute URL; keta routing only uses the path and query.
/// The real `Host` header is reflected into the authority when present (falling
/// back to localhost), so a shelf handler reading `requestedUri` sees it.
///
/// The `Host` header is attacker-controlled and unvalidated by the time it
/// reaches here, so `Uri.parse` on it can throw `FormatException` (a stray
/// space, an unterminated IPv6 bracket, …). Left uncaught that would surface as
/// a 500 for a malformed request that is properly the client's fault; it is
/// reported as a [BadRequest] (400) instead. `uri.hasQuery` (rather than
/// `uri.query.isEmpty`) decides whether to carry a query component, so a
/// bare-`?` request keeps its empty-but-present query instead of losing the
/// `?` entirely.
///
/// The parsed `Host` is never reflected wholesale into the base URI: a Host
/// header names an authority alone (`host[:port]`), so `Uri.parse` recovering
/// a userInfo, path, query, or fragment from it means the header carried
/// structure it has no business carrying — `Host: evil.com?inject=1` parses
/// cleanly to host `evil.com` with query `inject=1`, and `Uri.replace(query:
/// null)` keeps whatever query the *base* already has, so that injected query
/// (and likewise a smuggled `#fragment` or `user@` userInfo) would otherwise
/// reach the shelf handler's `requestedUri` as if the client had put it on the
/// request line. Such a Host is rejected as a [BadRequest] rather than
/// stripped down to its host+port: it is already-malformed, attacker-shaped
/// input, and rejecting it is consistent with the unterminated-bracket and
/// invalid-port cases above, which are also just "parse failed" from the
/// caller's point of view. What is reflected forward is a *rebuilt* URI made
/// only from the validated host and (optional) port — never the parsed Host
/// URI itself — so no component `Uri.parse` might have recovered from the raw
/// header can ride along.
Uri _absolute(Uri uri, String? host) {
  if (uri.hasScheme) return uri;
  final authority = (host == null || host.isEmpty) ? 'localhost' : host;
  final Uri parsedHost;
  try {
    parsedHost = Uri.parse('http://$authority');
  } on FormatException {
    throw BadRequest('malformed Host header: $host');
  }
  if (parsedHost.userInfo.isNotEmpty ||
      parsedHost.path.isNotEmpty ||
      parsedHost.hasQuery ||
      parsedHost.hasFragment) {
    throw BadRequest('malformed Host header: $host');
  }
  final base = Uri(
    scheme: 'http',
    host: parsedHost.host,
    port: parsedHost.hasPort ? parsedHost.port : null,
  );
  return base.replace(path: uri.path, query: uri.hasQuery ? uri.query : null);
}

/// Passes [source] through while counting bytes, failing with a [PayloadTooLarge]
/// once the cumulative size exceeds [maxBytes] — so App.maxBodyBytes is
/// enforced at the transport-ingestion point, bridge-independently.
Stream<List<int>> _limited(Stream<List<int>> source, int maxBytes) async* {
  var total = 0;
  await for (final chunk in source) {
    total += chunk.length;
    if (total > maxBytes) {
      throw PayloadTooLarge('request body exceeds $maxBytes bytes');
    }
    yield chunk;
  }
}

class _ShelfRequest implements TransportRequest {
  _ShelfRequest(this._request);
  final shelf.Request _request;

  @override
  String get method => _request.method;

  @override
  Uri get uri => _request.requestedUri;

  @override
  Map<String, List<String>> get headers => {
    for (final entry in _request.headersAll.entries)
      entry.key.toLowerCase(): entry.value,
  };

  @override
  Stream<List<int>> get bodyStream => _request.read();

  // shelf exposes no connection-close signal, so disconnect is not observed.
  @override
  Future<void> get closed => Completer<void>().future;

  @override
  String get remoteAddress {
    // shelf_io stores a dart:io HttpConnectionInfo here; any other server that
    // doesn't populate it leaves remoteAddress ''.
    final info = _request.context['shelf.io.connection_info'];
    return info is HttpConnectionInfo ? info.remoteAddress.address : '';
  }
}
