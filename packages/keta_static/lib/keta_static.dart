/// keta_static — static asset serving for keta, mounted as a prefix-scoped
/// middleware with the asset source behind a seam.
///
/// Serving static files was a judged absence in keta v0.1, and this package is
/// how it comes back rather than a reversal of that judgement: core still does
/// not serve files, still depends on nothing beyond the SDK, and an application
/// that does not mount assets does not carry any of this. Peel the package off
/// and nothing else changes.
library;

export 'src/asset.dart'
    show
        Asset,
        AssetSource,
        DirectoryAssets,
        MemoryAssets,
        contentTypeOf,
        defaultContentTypes,
        fnv1a64Hex;
export 'src/serve.dart' show staticFiles;
