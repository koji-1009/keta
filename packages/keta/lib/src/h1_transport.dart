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
    final wrapped = _H1Request(request);
    Response response;
    try {
      response = await _onRequest(wrapped);
    } catch (error, stack) {
      // The app applies a last-resort fallback, so this is defensive only.
      _onError(error, stack);
      response = Response(500, body: '');
    }
    await _write(request.response, wrapped, response);
  }

  Future<void> _write(
    HttpResponse out,
    _H1Request request,
    Response response,
  ) async {
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
      // Before framing the response, sever the connection if the handler left
      // a declared request body unread — otherwise dart:io would drain an
      // arbitrarily large upload at close (see [_H1Request.severIfBodyUnread]).
      request.severIfBodyUnread(out);
      final body = response.body;
      switch (body) {
        // A known-length body is framed with Content-Length; only a stream,
        // whose length is unknown up front, falls back to chunked framing
        // (contentLength left at its -1 sentinel). Framing is the Transport's
        // responsibility, so this is computed here, not carried on Response.
        case String():
          final bytes = utf8.encode(body);
          out.contentLength = bytes.length;
          out.add(bytes);
        case List<int>():
          out.contentLength = body.length;
          out.add(body);
        case Stream<List<int>>():
          await out.addStream(body);
      }
      await out.close();
    } catch (error, stack) {
      // Header/framing errors and mid-stream body failures land here. When a
      // stream body throws mid-write, dart:io has already marked the outgoing
      // as errored: close() then emits no terminating chunk and the connection
      // is destroyed, so the client sees a truncated response rather than one
      // framed as complete. Log rather than swallow, and still call close() to
      // release the connection.
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
    // Client-disconnect detection is only partial on dart:io's HttpServer:
    // while a request is handled it pauses the socket's read subscription
    // (http_impl.dart), so a client that drops the connection *after* the full
    // request is received and *before* the server writes cannot be observed —
    // there is no event until the next write attempt. Two signals are wired for
    // the cases that ARE observable:
    //  * response.done erroring — a write hitting the dropped socket (this
    //    reliably fires for streamed/large responses that overflow the socket
    //    buffer; a small buffered write to a just-closed loopback socket may
    //    still complete normally, so it is not a guarantee);
    //  * the request body erroring mid-receive — a client that drops while
    //    still sending its body (wired in [_trackedBody]).
    // The residual gap (idle disconnect during a no-write handler) is inherent
    // to dart:io's HttpServer and documented on `TransportRequest.closed`.
    _request.response.done.then(
      (_) {},
      onError: (Object _) {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }
  final HttpRequest _request;
  final Completer<void> _closed = Completer<void>();

  /// Whether the body stream has been listened to (dart:io latches
  /// `hasSubscriber` true on the first listen and never clears it).
  bool _bodyListened = false;

  /// Whether the body stream ran to completion — the whole declared body was
  /// received.
  bool _bodyFullyRead = false;

  @override
  Future<void> get closed => _closed.future;

  @override
  String get method => _request.method;

  @override
  Uri get uri => _request.uri;

  @override
  Stream<List<int>> get bodyStream => _body;

  /// Relays the raw body while recording whether it was fully received, with
  /// backpressure preserved. A mid-receive error is the client dropping the
  /// connection, so `closed` completes there too — the disconnect signal that
  /// dart:io *can* deliver. (An explicit subscription, not `yield*`, because
  /// `yield*` forwards the inner stream's errors straight past the generator's
  /// try/catch to the listener, leaving the drop unseen here.)
  late final Stream<List<int>> _body = _makeBody();

  Stream<List<int>> _makeBody() {
    final controller = StreamController<List<int>>();
    controller.onListen = () {
      _bodyListened = true;
      final sub = _request.listen(
        controller.add,
        onError: (Object e, StackTrace st) {
          if (!_closed.isCompleted) _closed.complete();
          controller.addError(e, st);
        },
        onDone: () {
          _bodyFullyRead = true;
          controller.close();
        },
      );
      controller
        ..onPause = sub.pause
        ..onResume = sub.resume
        ..onCancel = sub.cancel;
    };
    return controller.stream;
  }

  /// Whether the request declares a body worth defending against — a positive
  /// Content-Length or chunked transfer-encoding.
  bool get _bodyDeclared =>
      _request.contentLength > 0 || _request.headers.chunkedTransferEncoding;

  /// Called once the response is framed: if the handler never fully read a
  /// declared request body, refuse the connection so dart:io does not drain an
  /// unbounded upload and the dirty connection is not reused for keep-alive.
  ///
  /// dart:io auto-drains an unread body of any size at response completion, but
  /// skips that drain once the body has been listened to even once. So a body
  /// that was never touched is given a subscriber — paused, so not a byte is
  /// read — to latch the skip; a partially-read body already latched it.
  /// Cancelling instead of pausing would let dart:io treat the body as done and
  /// destroy the connection before the response is flushed, so the subscription
  /// is held (paused) until the non-persistent connection closes on its own.
  void severIfBodyUnread(HttpResponse out) {
    if (!_bodyDeclared || _bodyFullyRead) return;
    if (!_bodyListened) {
      // Listen (latching the drain-skip) and immediately pause: never a byte is
      // read, and the paused subscription stays alive — held by the incoming
      // stream — until the non-persistent connection closes on its own.
      // Cancelling instead would let dart:io treat the body as done and destroy
      // the connection before the response is flushed.
      // ignore: cancel_subscriptions
      _request.listen(null, cancelOnError: false).pause();
    }
    out.persistentConnection = false;
  }

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
