library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Normalizes [path] to the stable, machine-independent key a diagnostic's id
/// is hashed from, so `sha256(file|scope|rule)` agrees across the IDE and the
/// CLI and across machines.
///
/// The two producers otherwise disagree by construction: the analyzer plugin is
/// handed an *absolute* path (`/Users/alice/proj/lib/a.dart`), while the CLI is
/// handed *whatever the user typed* (`lib/a.dart`, `./lib/a.dart`, or an
/// absolute path on another machine). Hashing either raw form makes the same
/// finding carry a different id in the IDE than on CI, and a different id on
/// every checkout — defeating the correlation the id exists for.
///
/// The fix is to key on the path *within its package*: locate the nearest
/// ancestor directory holding a `pubspec.yaml` (the package root) and return the
/// path relative to it, in POSIX form so a Windows checkout and a macOS checkout
/// of the same repo hash identically. When no package root is found (a scratch
/// file, an in-memory `<memory>` path), the basename is the most stable key
/// available and is used as the fallback.
String packageRelativePath(String path) {
  // `<memory>` and other non-filesystem sentinels have no root to resolve
  // against; treat them verbatim so in-memory diagnostics keep a stable key.
  if (!path.contains(p.separator) && !path.contains('/')) return path;

  final absolute = p.normalize(p.absolute(path));
  final root = _packageRoot(absolute);
  if (root == null) return p.basename(absolute);
  final relative = p.relative(absolute, from: root);
  // POSIX-normalize the separators so the id does not depend on the host OS.
  return p.posix.joinAll(p.split(relative));
}

/// The nearest ancestor of [absolutePath] (inclusive of its own directory) that
/// holds a `pubspec.yaml`, or null when the filesystem root is reached without
/// finding one.
String? _packageRoot(String absolutePath) {
  var dir = _isDirectory(absolutePath) ? absolutePath : p.dirname(absolutePath);
  while (true) {
    if (File(p.join(dir, 'pubspec.yaml')).existsSync()) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) return null; // reached the filesystem root
    dir = parent;
  }
}

bool _isDirectory(String path) {
  // A path that does not exist yet (e.g. a file the CLI was asked to hash
  // before it is created) is treated as a file, so we search from its parent.
  try {
    return FileSystemEntity.isDirectorySync(path);
  } on FileSystemException {
    return false;
  }
}
