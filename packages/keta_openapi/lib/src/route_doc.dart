library;

import 'schema.dart';

/// Per-route documentation, passed to a route as its opaque `doc` and read back
/// here when emitting OpenAPI.
class RouteDoc {
  /// The schema of the 200 response body.
  final Schema? response;

  /// The schema of the request body.
  final Schema? requestBody;

  final String? summary;

  /// Responses for statuses other than 200.
  final Map<int, Schema>? responses;

  const RouteDoc({
    this.response,
    this.requestBody,
    this.summary,
    this.responses,
  });

  /// Every schema this doc references, for transitive component collection.
  Iterable<Schema> get schemas => [
        if (response != null) response!,
        if (requestBody != null) requestBody!,
        ...?responses?.values,
      ];
}
