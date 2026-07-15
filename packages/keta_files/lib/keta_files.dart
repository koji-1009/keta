/// keta_files — file-based routing for keta.
///
/// The file's location IS the URL: `routes/users/_id.dart` serves `/users/:id`.
/// Nothing inside the file says where it lives, which is the whole point — the
/// tree is the route table, and reading the tree is reading the routes.
///
/// A route file exports a function per HTTP verb (`get`, `post`, ...), an
/// optional `<verb>Doc` for its OpenAPI, and an optional `captures` map giving
/// its parameters' types. The tree says *where*; the file says *what*.
///
/// `dart run keta_files:sync` materializes the bindings into the manifest's
/// marked regions, so what runs is ordinary keta code you can read.
library;

export 'src/discover.dart'
    show RouteFile, capturesDeclaration, discoverRouteFiles, httpMethods;
export 'src/manifest.dart' show registrationsFor, syncManifest, unregistered;
export 'src/route_path.dart' show routeSegments;
