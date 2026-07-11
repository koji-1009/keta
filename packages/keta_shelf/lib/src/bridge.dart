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
    final response = await router.dispatch(_ShelfRequest(request));
    return shelf.Response(
      response.status,
      body: response.body,
      headers: response.headers,
    );
  };
}

/// Adapts a shelf [handler] into a keta terminal [Handler], so shelf handlers
/// and middleware can run inside a keta route.
Handler<E> shelfToKeta<E>(shelf.Handler handler) {
  return (Context<E> c) async {
    final body = await c.bodyBytes();
    final request = shelf.Request(
      c.method,
      _absolute(c.uri),
      headers: c.headers,
      body: body.isEmpty ? null : body,
    );
    final response = await handler(request);
    final bytes = await response.read().expand((chunk) => chunk).toList();
    final headers = {...response.headers}..remove('content-length');
    return Response(response.statusCode, headers: headers, body: bytes);
  };
}

/// shelf requires an absolute URL; keta routing only uses the path and query.
Uri _absolute(Uri uri) => uri.hasScheme
    ? uri
    : Uri(scheme: 'http', host: 'localhost', path: uri.path, query: uri.query.isEmpty ? null : uri.query);

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

  @override
  String get remoteAddress {
    final info = _request.context['shelf.io.connection_info'];
    return info is Map ? (info['remoteAddress']?.toString() ?? '') : '';
  }
}
