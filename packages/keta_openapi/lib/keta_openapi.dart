/// keta_openapi — emission only: the route-table walk that renders an OpenAPI
/// 3.1 document from a keta app's declarations.
///
/// The declaration contract (`Schema`, `RouteDoc`, the security types) lives in
/// keta, where it validates requests and gates them at runtime. This package
/// only reads those declarations and projects them one way into a document; the
/// document is a shadow of the routes and never a source that drives them. It is
/// removable without changing any runtime behaviour.
library;

export 'src/openapi.dart' show OpenApi;
