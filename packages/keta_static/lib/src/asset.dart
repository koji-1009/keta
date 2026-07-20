library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One servable representation: its bytes, its media type, and the validator
/// that identifies this version of it.
final class Asset {
  Asset({required this.bytes, required this.contentType, String? etag})
    : etag = etag ?? fnv1a64Hex(bytes);

  final Uint8List bytes;
  final String contentType;

  /// The opaque entity-tag value, unquoted. Defaults to FNV-1a 64 over the
  /// bytes — a cache validator needs a fast fingerprint, not collision
  /// resistance, which is the same reasoning `etag()` uses in core.
  final String etag;

  int get length => bytes.length;
}

/// Where [Asset]s come from.
///
/// This seam is the whole reason static serving does not decide anything about
/// distribution. A directory on disk is one implementation; assets held in
/// memory, generated at build time, or produced by a build hook and bundled
/// into the executable are others, and none of them changes a line here. If
/// data assets graduate out of experimental, they arrive as a source — not as
/// a change to this package.
abstract interface class AssetSource {
  /// Resolves a request path already stripped of its mount prefix (`app.js`,
  /// `img/logo.png`, or `''` for the mount root), or null when there is no
  /// such asset.
  ///
  /// The path handed here has already been rejected if it could escape the
  /// source (see the mount's traversal guard); a source that reaches a real
  /// filesystem should still refuse anything it does not recognize rather than
  /// trust that.
  Future<Asset?> resolve(String path);
}

/// Serves assets from a directory on disk, reading each file on demand.
///
/// Deliberately not a cache: a cache's invalidation policy is an application
/// decision (a long-running server may want every asset resident, a
/// development server wants none of it), and baking one in here would take
/// that decision away. [MemoryAssets] is the caching implementation, built by
/// the application from whatever it wants resident.
final class DirectoryAssets implements AssetSource {
  DirectoryAssets(
    this.root, {
    this.indexFile = 'index.html',
    Map<String, String>? contentTypes,
  }) : contentTypes = contentTypes ?? defaultContentTypes;

  /// The directory assets are read from. Resolved once, so a later `cd` cannot
  /// move the root out from under the traversal guard.
  final Directory root;

  /// The file served for a path that names a directory (`''` → `index.html`).
  /// Null serves nothing for such a path.
  final String? indexFile;

  /// Extension (without the dot, lower-case) to media type.
  final Map<String, String> contentTypes;

  @override
  Future<Asset?> resolve(String path) async {
    final relative = path.isEmpty || path.endsWith('/')
        ? (indexFile == null ? null : '$path$indexFile')
        : path;
    if (relative == null) return null;
    final file = File('${root.path}/$relative');
    if (!file.existsSync()) return null;
    // A path that resolves outside the root — through a symlink, since textual
    // traversal was already refused upstream — is not this source's to serve.
    final resolved = file.resolveSymbolicLinksSync();
    final rootPath = root.resolveSymbolicLinksSync();
    if (!resolved.startsWith('$rootPath/')) return null;
    return Asset(
      bytes: await file.readAsBytes(),
      contentType: contentTypeOf(relative, contentTypes),
    );
  }
}

/// Serves assets held in memory, by exact path.
///
/// The implementation an application reaches for when the bytes are already
/// in hand — embedded by a build step, produced at boot, or read once from
/// disk at startup.
final class MemoryAssets implements AssetSource {
  MemoryAssets(this.assets, {this.indexFile = 'index.html'});

  /// Builds a source from path → bytes, deriving each media type from its
  /// extension.
  factory MemoryAssets.ofBytes(
    Map<String, List<int>> files, {
    String? indexFile = 'index.html',
    Map<String, String>? contentTypes,
  }) => MemoryAssets({
    for (final entry in files.entries)
      entry.key: Asset(
        bytes: Uint8List.fromList(entry.value),
        contentType: contentTypeOf(
          entry.key,
          contentTypes ?? defaultContentTypes,
        ),
      ),
  }, indexFile: indexFile);

  /// Builds a source from path → text, encoded UTF-8.
  factory MemoryAssets.ofText(
    Map<String, String> files, {
    String? indexFile = 'index.html',
    Map<String, String>? contentTypes,
  }) => MemoryAssets.ofBytes(
    {for (final e in files.entries) e.key: utf8.encode(e.value)},
    indexFile: indexFile,
    contentTypes: contentTypes,
  );

  /// Path (no leading slash) to asset.
  final Map<String, Asset> assets;
  final String? indexFile;

  @override
  Future<Asset?> resolve(String path) async {
    final key = path.isEmpty || path.endsWith('/')
        ? (indexFile == null ? null : '$path$indexFile')
        : path;
    return key == null ? null : assets[key];
  }
}

/// The media type for [path]'s extension, or `application/octet-stream`.
///
/// Unknown means octet-stream rather than a guess: a wrong `text/html` on
/// attacker-supplied content is an XSS vector, and octet-stream is the answer
/// that cannot be one.
String contentTypeOf(String path, Map<String, String> contentTypes) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  if (dot <= slash + 1) return 'application/octet-stream';
  final extension = path.substring(dot + 1).toLowerCase();
  return contentTypes[extension] ?? 'application/octet-stream';
}

/// Media types for the extensions a web build actually emits. Text formats
/// carry `charset=utf-8`; anything absent is octet-stream (see
/// [contentTypeOf]).
const Map<String, String> defaultContentTypes = {
  'html': 'text/html; charset=utf-8',
  'htm': 'text/html; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'map': 'application/json; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
  'xml': 'application/xml; charset=utf-8',
  'svg': 'image/svg+xml',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'avif': 'image/avif',
  'ico': 'image/x-icon',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'wasm': 'application/wasm',
  'pdf': 'application/pdf',
};

/// FNV-1a 64 over [bytes], rendered as 16 hex characters — the same validator
/// shape core's `etag()` produces.
String fnv1a64Hex(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b;
    hash *= 0x100000001b3;
  }
  final hi = (hash >> 32) & 0xffffffff;
  final lo = hash & 0xffffffff;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
