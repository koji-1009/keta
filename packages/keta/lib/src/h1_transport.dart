library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'response.dart';
import 'transport.dart';

/// The default HTTP/1.1 transport, built on `dart:io`. Uses only the SDK, so
/// the core's zero-dependency rule holds even with a transport bundled.
///
/// No path lets an error escape to the root zone: request handling, response
/// writing, and connection acceptance all report failures through [onError]
/// instead of terminating the isolate.
class H1Transport implements Transport {
  const H1Transport({this.address, this.onError});

  /// The bind address; defaults to all IPv4 interfaces when null.
  final Object? address;

  /// Reports transport-level failures (write errors, accept errors) instead of
  /// letting them reach the root zone. Falls back to stderr when null.
  final void Function(Object error, StackTrace stack)? onError;

  @override
  Future<TransportServer> bind(
    int port,
    FutureOr<Response> Function(TransportRequest) onRequest,
  ) async {
    // shared: true lets every isolate bind the same port and share the accept
    // queue, so serve(isolates: n) needs no extra coordination.
    final server = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    return _H1Server(server, onRequest, onError ?? _toStderr);
  }
}

void _toStderr(Object error, StackTrace stack) {
  stderr.writeln('keta H1 transport error: $error');
}

class _H1Server implements TransportServer {
  _H1Server(this._server, this._onRequest, this._onError) {
    _server.listen(_accept, onError: _onError);
  }
  final HttpServer _server;
  final FutureOr<Response> Function(TransportRequest) _onRequest;
  final void Function(Object, StackTrace) _onError;
  final Set<Future<void>> _inFlight = {};

  void _accept(HttpRequest request) {
    // _handle never throws (it catches internally), but guard the derived
    // future so no rejection can reach the root zone.
    final done = _handle(request).catchError(_onError);
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
  }

  Future<void> _handle(HttpRequest request) async {
    Response response;
    try {
      response = await _onRequest(_H1Request(request));
    } catch (error, stack) {
      // The app applies a last-resort fallback, so this is defensive only.
      _onError(error, stack);
      response = Response(500, body: '');
    }
    await _write(request.response, response);
  }

  Future<void> _write(HttpResponse out, Response response) async {
    try {
      out.statusCode = response.status;
      response.headers.forEach((name, values) {
        // Framing is the Transport's to compute; user-supplied framing headers
        // are ignored so a stale content-length can never corrupt the wire.
        if (name == 'content-length' || name == 'transfer-encoding') return;
        out.headers.removeAll(name);
        for (final value in values) {
          out.headers.add(name, value);
        }
      });
      final body = response.body;
      switch (body) {
        case String():
          out.add(utf8.encode(body));
        case List<int>():
          out.add(body);
        case Stream<List<int>>():
          await out.addStream(body);
      }
      await out.close();
    } catch (error, stack) {
      // Header/framing errors and mid-stream body failures land here. Log
      // rather than swallow, and destroy the connection so a partially-written
      // body is never framed as a complete response.
      _onError(error, stack);
      try {
        await out.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> close({Duration grace = const Duration(seconds: 30)}) async {
    // Stop accepting, wait out in-flight requests within the grace window, then
    // force-close anything still lingering.
    final stopped = _server.close();
    if (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight).timeout(grace, onTimeout: () => const []);
    }
    await _server.close(force: true).catchError((_) {});
    await stopped.catchError((_) {});
  }
}

class _H1Request implements TransportRequest {
  _H1Request(this._request) {
    // A client dropping the connection surfaces as an error on response.done;
    // signal cancellation then. A normal completion leaves `closed` pending
    // (the request finished on its own — nothing to cancel).
    _request.response.done.then(
      (_) {},
      onError: (Object _) {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }
  final HttpRequest _request;
  final Completer<void> _closed = Completer<void>();

  @override
  Future<void> get closed => _closed.future;

  @override
  String get method => _request.method;

  @override
  Uri get uri => _request.uri;

  @override
  Stream<List<int>> get bodyStream => _request;

  @override
  String get remoteAddress =>
      _request.connectionInfo?.remoteAddress.address ?? '';

  @override
  Map<String, List<String>> get headers {
    final result = <String, List<String>>{};
    _request.headers.forEach((name, values) {
      result[name.toLowerCase()] = values;
    });
    return result;
  }
}
