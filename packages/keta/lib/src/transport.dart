library;

import 'dart:async';

import 'response.dart';

/// The seam between the core's HTTP semantics and a concrete wire protocol.
///
/// The core produces and consumes method/uri/headers/status/body only; framing,
/// TLS, multiplexing, and connection management live behind this interface.
/// Keeping `dart:io` types out of these signatures is what lets the core stay
/// transport-agnostic (H1 today, H2/H3 later).
abstract interface class Transport {
  /// Starts listening on [port], invoking [onRequest] for each request.
  Future<TransportServer> bind(
    int port,
    FutureOr<Response> Function(TransportRequest) onRequest,
  );
}

/// One inbound request, in transport-neutral terms.
abstract interface class TransportRequest {
  String get method;
  Uri get uri;

  /// Header names lower-cased.
  Map<String, String> get headers;

  /// The request body as it arrives; the core buffers or streams as needed.
  Stream<List<int>> get bodyStream;

  /// The peer address.
  String get remoteAddress;

  /// Completes when the Transport observes the connection close before the
  /// response is finished (a client disconnect). The core wires this to
  /// `ctx.abort()`, fulfilling the client-disconnect clause of `c.aborted`. A
  /// transport that cannot detect disconnect returns a future that never
  /// completes.
  Future<void> get closed;
}

/// A running server bound by a [Transport].
abstract interface class TransportServer {
  /// Stops accepting new connections and waits out in-flight requests up to
  /// [grace] before forcing them closed.
  Future<void> close({Duration grace});
}
