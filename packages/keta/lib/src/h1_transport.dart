library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'response.dart';
import 'transport.dart';

/// The default HTTP/1.1 transport, built on `dart:io`. Uses only the SDK, so
/// the core's zero-dependency rule holds even with a transport bundled.
class H1Transport implements Transport {
  /// The bind address; defaults to all IPv4 interfaces when null.
  final Object? address;

  const H1Transport({this.address});

  @override
  Future<TransportServer> bind(
    int port,
    FutureOr<Response> Function(TransportRequest) onRequest,
  ) async {
    // shared: true lets every isolate bind the same port and share the accept
    // queue, so serve(isolates: n) needs no extra coordination.
    final server = await HttpServer.bind(
        address ?? InternetAddress.anyIPv4, port,
        shared: true);
    return _H1Server(server, onRequest);
  }
}

class _H1Server implements TransportServer {
  final HttpServer _server;
  final FutureOr<Response> Function(TransportRequest) _onRequest;
  final Set<Future<void>> _inFlight = {};

  _H1Server(this._server, this._onRequest) {
    _server.listen(_accept);
  }

  void _accept(HttpRequest request) {
    final done = _handle(request);
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
  }

  Future<void> _handle(HttpRequest request) async {
    final response = await _onRequest(_H1Request(request));
    await _write(request.response, response);
  }

  Future<void> _write(HttpResponse out, Response response) async {
    out.statusCode = response.status;
    response.headers.forEach(out.headers.set);
    final body = response.body;
    try {
      switch (body) {
        case String():
          out.add(utf8.encode(body));
        case List<int>():
          out.add(body);
        case Stream<List<int>>():
          await out.addStream(body);
      }
      await out.close();
    } catch (_) {
      // The client vanished mid-write; abandon the response quietly.
      await out.close().catchError((_) {});
    }
  }

  @override
  Future<void> close({Duration grace = const Duration(seconds: 30)}) async {
    // Stop accepting, then let in-flight requests finish within the grace
    // window before closing connections by force.
    await _server.close();
    if (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight).timeout(grace, onTimeout: () => const []);
    }
  }
}

class _H1Request implements TransportRequest {
  final HttpRequest _request;

  _H1Request(this._request);

  @override
  String get method => _request.method;

  @override
  Uri get uri => _request.uri;

  @override
  Stream<List<int>> get bodyStream => _request;

  @override
  String get remoteAddress => _request.connectionInfo?.remoteAddress.address ?? '';

  @override
  Map<String, String> get headers {
    final result = <String, String>{};
    _request.headers.forEach((name, values) {
      result[name.toLowerCase()] = values.join(', ');
    });
    return result;
  }
}
