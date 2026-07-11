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
}

/// A running server bound by a [Transport].
abstract interface class TransportServer {
  /// Stops accepting new connections and waits out in-flight requests up to
  /// [grace] before forcing them closed.
  Future<void> close({Duration grace});
}
