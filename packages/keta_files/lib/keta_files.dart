/// keta_files — file-based routing for keta.
///
/// The file's location IS the URL: `routes/users/_id.dart` serves `/users/:id`.
/// Nothing inside the file says where it lives, which is the whole point — the
/// tree is the route table, and reading the tree is reading the routes.
///
/// One file is one URL, so it is one value: a route file declares a single
/// `exported`, with a slot per method it answers and the types of the captures
/// its location declares. The tree says *where*; the file says *what*.
///
/// `dart run keta_files:sync` materializes the bindings into the manifest's
/// marked regions, so what runs is ordinary keta code you can read.
library;

export 'src/discover.dart' show RouteFile, discoverRouteFiles;
export 'src/export.dart' show Exported, Serve, exportedDeclaration;
export 'src/manifest.dart' show registrationFor, syncManifest, unregistered;
export 'src/route_path.dart' show routeSegments;
