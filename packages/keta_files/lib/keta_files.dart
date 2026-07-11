/// keta_files — file-convention route registration. Discovers route files and
/// materializes their imports and `register(app)` calls into a manifest's
/// marked regions, without touching any code outside those markers.
library;

export 'src/manifest.dart'
    show RouteFile, discoverRouteFiles, syncManifest, unregistered;
