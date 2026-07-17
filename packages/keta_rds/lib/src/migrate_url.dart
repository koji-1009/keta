library;

/// The URL schemes `keta_rds:migrate` accepts. Both are the same protocol;
/// PostgreSQL tooling uses them interchangeably, and package:postgres parses
/// either.
const _schemes = {'postgres', 'postgresql'};

/// Validates that [url] names a PostgreSQL connection (a `postgres://` or
/// `postgresql://` URL) and returns it unchanged.
///
/// Throws a [FormatException] naming the offending scheme otherwise — the
/// migrate bin turns that into an exit 64 (usage error), the same contract as
/// `keta_sqlite:migrate`. This is a pure syntactic gate; whether the host is
/// reachable is discovered later, when a connection is opened.
String requirePostgresUrl(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException {
    throw FormatException('not a valid URL', url);
  }
  if (!_schemes.contains(uri.scheme)) {
    throw FormatException(
      'expected a postgres:// or postgresql:// URL, got scheme '
      '"${uri.scheme}"',
      url,
    );
  }
  return url;
}
