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
/// Middleware scopes the same way: a `_middleware.dart` file declares a single
/// `scoped`, and its *directory* is the subtree it wraps. `routes/admin/_middleware.dart`
/// guards every route under `/admin` — the file-based answer to
/// `app.group('/admin').use(...)`, with the directory standing in for the prefix.
///
/// `dart run keta_files:sync` materializes the bindings into the manifest's
/// marked regions, so what runs is ordinary keta code you can read.
library;

export 'src/discover.dart'
    show Discovery, MiddlewareFile, RouteFile, discover, orphanMiddleware;
export 'src/export.dart'
    show
        Exported,
        ScopedMiddleware,
        Serve,
        exportedDeclaration,
        scopedDeclaration;
export 'src/manifest.dart' show registrationFor, syncManifest, unregistered;
export 'src/route_path.dart' show routeSegments;
