library;

import 'dart:async';

import 'package:keta/keta.dart';
import 'package:shelf/shelf.dart' as shelf;

/// Mounts a keta [app] as a shelf handler: it compiles the app once (so route
/// conflicts fail fast here) and runs the full keta pipeline per request. Use
/// it to serve keta from an existing shelf stack.
shelf.Handler ketaToShelf<E>(App<E> app, E env, {int maxBodyBytes = 1 << 20}) {
  final router = app.compile(env, maxBodyBytes: maxBodyBytes);
  return (shelf.Request request) async {
    // keta handlers read the body through Context, which enforces maxBodyBytes
    // at its buffering point; bodyStream() stays the deliberate escape.
    final response = await router.dispatch(_ShelfRequest(request));
    // Drop framing headers keta may have set: the body is re-framed by shelf /
    // the server, and a stale content-length on a stream body corrupts the wire.
    final headers = {...response.headers}
      ..removeWhere((k, _) => k == 'content-length' || k == 'transfer-encoding');
    return shelf.Response(response.status, body: response.body, headers: headers);
  };
}

/// Adapts a shelf [handler] into a keta terminal [Handler], so shelf handlers
/// and middleware can run inside a keta route.
///
/// Request and response bodies are streamed through unbuffered, so large
/// uploads and long-lived responses (SSE, chunked) work. The request stream
/// handed to the shelf handler is wrapped in a counting limiter that enforces
/// [maxBodyBytes] as a `KetaException(413)` stream error (set it to the app's
/// `maxBodyBytes`). Websocket hijack is not supported — keta's [Transport]
/// exposes no socket — and a `request.hijack()` surfaces as a `StateError`.
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
    // through and corrupt the wire).
    final headers = {...response.headers}
      ..removeWhere((k, _) =>
          k.toLowerCase() == 'content-length' ||
          k.toLowerCase() == 'transfer-encoding');
    return Response(response.statusCode,
        headers: headers, body: response.read());
  };
}

/// shelf requires an absolute URL; keta routing only uses the path and query.
/// The real `Host` header is reflected into the authority when present (falling
/// back to localhost), so a shelf handler reading `requestedUri` sees it.
Uri _absolute(Uri uri, String? host) {
  if (uri.hasScheme) return uri;
  final authority = (host == null || host.isEmpty) ? 'localhost' : host;
  return Uri.parse('http://$authority').replace(
    path: uri.path,
    query: uri.query.isEmpty ? null : uri.query,
  );
}

/// Passes [source] through while counting bytes, failing with `KetaException`
/// (413) once the cumulative size exceeds [maxBytes] — so App.maxBodyBytes is
/// enforced at the transport-ingestion point, bridge-independently.
Stream<List<int>> _limited(Stream<List<int>> source, int maxBytes) async* {
  var total = 0;
  await for (final chunk in source) {
    total += chunk.length;
    if (total > maxBytes) {
      throw KetaException(413, 'request body exceeds $maxBytes bytes');
    }
    yield chunk;
  }
}

class _ShelfRequest implements TransportRequest {
  final shelf.Request _request;

  _ShelfRequest(this._request);

  @override
  String get method => _request.method;

  @override
  Uri get uri => _request.requestedUri;

  @override
  Map<String, String> get headers => {
        for (final entry in _request.headers.entries)
          entry.key.toLowerCase(): entry.value,
      };

  @override
  Stream<List<int>> get bodyStream => _request.read();

  // shelf exposes no connection-close signal, so disconnect is not observed.
  @override
  Future<void> get closed => Completer<void>().future;

  @override
  String get remoteAddress {
    // shelf_io stores an HttpConnectionInfo object (not a Map) under this key.
    // Under any other shelf server that does not populate it, this is '' — IP
    // features (rate limiting, audit) silently see no peer address.
    final info = _request.context['shelf.io.connection_info'];
    if (info == null) return '';
    try {
      return (info as dynamic).remoteAddress.address as String? ?? '';
    } catch (_) {
      return '';
    }
  }
}
