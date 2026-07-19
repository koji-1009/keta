library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../jwt/jwk.dart';
import '../jwt/jws.dart';
import '../jwt/rejection.dart';
import 'jwk_set.dart';
import 'jwks_source.dart';

/// How the raw bytes of a URL are fetched. The HTTP source calls this and
/// nothing else for I/O, so every path — discovery, initial load, refresh,
/// timeout, failure — is testable without a socket by injecting a hook. The
/// default is a real [HttpClient] with the source's configured timeouts.
typedef JwksFetch = Future<String> Function(Uri url);

/// A [JwksSource] backed by an HTTP JWKS endpoint, with the caching and refresh
/// discipline that keeps a resource server both fast and hard to weaponize
/// against its own IdP.
///
/// ## Construction
///
/// * [HttpJwksSource.fromJwksUri] — the `jwks_uri` is known directly.
/// * [HttpJwksSource.discover] — only the `issuer` is known; the `jwks_uri` is
///   found once via OIDC Discovery (`<issuer>/.well-known/openid-configuration`),
///   and the discovery document's `issuer` field **must** equal the configured
///   issuer exactly (RFC 8414 §3.3) or it is a [JwksDiscoveryException]. The
///   discovered `jwks_uri` is cached; discovery runs once, not per refresh.
///
/// ## Transport security
///
/// * **HTTPS is required.** RFC 8414 §2 mandates an `https` issuer, and a
///   plaintext `jwks_uri` lets a network attacker substitute signing keys. Both
///   the configured issuer/`jwks_uri` (checked at construction, an
///   [ArgumentError]) and a `jwks_uri` learned from a discovery document
///   (checked when discovery runs, a [JwksDiscoveryException]) must be `https`.
/// * **Loopback exception.** Plaintext `http` is permitted **only** to a
///   loopback host (`localhost`, `127.0.0.0/8`, `::1`), where there is no
///   on-path attacker to defend against — this keeps local development against a
///   dev IdP possible without a global "trust plaintext" escape hatch.
/// * **Response size is capped.** Every fetch (discovery and JWKS) is bounded to
///   [_maxResponseBytes]; a body that exceeds it aborts the read and is treated
///   as a failed refresh (serve-stale if warm, [JwksUnavailable] if cold), so a
///   hostile or misbehaving endpoint cannot exhaust memory under the
///   coarse-grained total timeout alone.
///
/// ## Refresh discipline (the availability / anti-DoS core)
///
/// * **Happy path is cache-only.** A known `kid` in the cached set resolves with
///   no I/O.
/// * **Unknown `kid` triggers at most one refresh**, and that refresh is:
///   * **single-flight** — concurrent resolves for unknown `kid`s share one
///     in-flight fetch, never a thundering herd;
///   * **cooled down** — after a miss-triggered refresh, further ones are
///     suppressed for [minRefreshInterval]; within that window an unknown `kid`
///     is an immediate [JwtUnknownKey] with **no** fetch. An attacker spraying
///     garbage `kid`s therefore cannot turn this server into a hammer on the IdP.
/// * **Lazy TTL refresh.** A read of a set older than [ttl] refreshes it (subject
///   to the same [minRefreshInterval] throttle, so a persistent outage cannot
///   cause a fetch per request).
/// * **Serve-stale on refresh failure.** If a refresh fails but a previously
///   loaded set exists, that set keeps serving and the error is swallowed —
///   availability over freshness. The revocation story is short token lifetimes,
///   not JWKS freshness (a judged posture; introspection is out of scope). Only
///   a **cold** source (nothing ever loaded) surfaces the failure, as
///   [JwksUnavailable] wrapping the cause.
/// * **Cold failures are throttled too.** The very first cold load is exempt
///   from the cooldown (so startup is not delayed), but a cold load that *fails*
///   stamps the attempt time and parks its error: further reads within
///   [minRefreshInterval] re-surface that same failure with **no** fetch, so a
///   down IdP with nothing cached cannot be hammered once per request. The
///   parked error is cleared the instant a load succeeds, so recovery is
///   immediate.
/// * **No retry loops.** One fetch per trigger; no automatic re-tries (the
///   idempotency of a retried operation is not knowable here).
final class HttpJwksSource implements JwksSource {
  HttpJwksSource._(
    this._jwksUri, {
    required this.issuer,
    required JwksFetch? fetch,
    required this.ttl,
    required this.minRefreshInterval,
    required this.connectTimeout,
    required this.totalTimeout,
    required DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    // Reject a plaintext transport up front, before any I/O: a configured
    // `jwks_uri`, or the issuer whose discovery URL is derived from it. A
    // `jwks_uri` learned later from discovery is checked in [_resolveJwksUri].
    final configuredJwksUri = _jwksUri;
    if (configuredJwksUri != null) {
      _requireSecureUrl(configuredJwksUri, 'jwksUri');
    }
    final configuredIssuer = issuer;
    if (configuredIssuer != null) {
      _requireSecureUrl(_parseIssuer(configuredIssuer), 'issuer');
    }
    _fetch = fetch ?? (url) => _defaultFetch(url, connectTimeout, totalTimeout);
  }

  /// A source whose `jwks_uri` is known directly (no discovery).
  factory HttpJwksSource.fromJwksUri(
    Uri jwksUri, {
    JwksFetch? fetch,
    Duration ttl = const Duration(minutes: 15),
    Duration minRefreshInterval = const Duration(minutes: 5),
    Duration connectTimeout = const Duration(seconds: 5),
    Duration totalTimeout = const Duration(seconds: 10),
    DateTime Function()? now,
  }) => HttpJwksSource._(
    jwksUri,
    issuer: null,
    fetch: fetch,
    ttl: ttl,
    minRefreshInterval: minRefreshInterval,
    connectTimeout: connectTimeout,
    totalTimeout: totalTimeout,
    now: now,
  );

  /// A source that finds its `jwks_uri` via OIDC Discovery from [issuer]. The
  /// discovery document's `issuer` must equal [issuer] exactly.
  factory HttpJwksSource.discover({
    required String issuer,
    JwksFetch? fetch,
    Duration ttl = const Duration(minutes: 15),
    Duration minRefreshInterval = const Duration(minutes: 5),
    Duration connectTimeout = const Duration(seconds: 5),
    Duration totalTimeout = const Duration(seconds: 10),
    DateTime Function()? now,
  }) => HttpJwksSource._(
    null,
    issuer: issuer,
    fetch: fetch,
    ttl: ttl,
    minRefreshInterval: minRefreshInterval,
    connectTimeout: connectTimeout,
    totalTimeout: totalTimeout,
    now: now,
  );

  /// The configured issuer for OIDC Discovery, or `null` when the `jwks_uri` was
  /// given directly.
  final String? issuer;

  /// The maximum age of a cached set before a read refreshes it lazily.
  final Duration ttl;

  /// The minimum gap between refresh *attempts* (both miss-triggered and
  /// TTL-triggered); the cold initial load is exempt.
  final Duration minRefreshInterval;

  /// The per-connection timeout applied by the default fetch.
  final Duration connectTimeout;

  /// The total per-request timeout applied by the default fetch.
  final Duration totalTimeout;

  final DateTime Function() _now;
  late final JwksFetch _fetch;

  /// The `jwks_uri`: given up front, or discovered and cached on first fetch.
  Uri? _jwksUri;

  /// The current cached set (`null` before any successful load).
  JwkSet? _set;

  /// When [_set] was last successfully loaded, for TTL staleness.
  DateTime? _loadedAt;

  /// When a refresh was last *attempted*, for [minRefreshInterval]. Set for
  /// non-cold refreshes and for *failed* cold loads (see [_recordColdFailure]);
  /// a successful cold load stays exempt, so the first miss after startup can
  /// still refresh immediately.
  DateTime? _lastRefreshAt;

  /// The error from the most recent *cold* refresh failure (nothing cached),
  /// parked so reads within [minRefreshInterval] re-surface it without another
  /// fetch. Cleared the moment a load succeeds. `null` while warm or healthy.
  Object? _coldFailure;

  /// The single in-flight fetch, if one is running (single-flight).
  Future<JwkSet>? _inFlight;

  /// The discovered/parsed `jwks_uri`, or `null` if discovery has not run yet.
  /// Exposed for tests to confirm discovery extraction.
  Uri? get resolvedJwksUri => _jwksUri;

  @override
  Future<Jwk> resolve(JoseHeader header) async {
    var set = await _currentSet();
    var jwk = set.lookup(header);
    if (jwk != null) return jwk;

    // A miss on a real `kid` may just mean the key rotated in since the last
    // fetch: refresh once (single-flight, cooled down) and look again. A
    // `kid`-less miss cannot be fixed by more keys (it is ambiguous by
    // definition), so it never triggers a fetch.
    if (header.kid != null) {
      final refresh = _refreshForMiss();
      if (refresh != null) {
        set = await refresh;
        jwk = set.lookup(header);
        if (jwk != null) return jwk;
      }
    }
    throw JwtUnknownKey(_missMessage(header, set));
  }

  /// The set to read now: the cached one, cold-loaded if none, or lazily
  /// refreshed if past [ttl] and not throttled.
  Future<JwkSet> _currentSet() {
    final set = _set;
    if (set == null) {
      // Cold: nothing cached. Join a load already in flight; otherwise attempt
      // one — unless a prior cold attempt failed within the cooldown, in which
      // case re-surface that parked failure with no I/O (a down IdP must not be
      // fetched once per request). The first-ever attempt is exempt because
      // _lastRefreshAt is still null, so _cooldownElapsed() is true.
      final inflight = _inFlight;
      if (inflight != null) return inflight;
      if (!_cooldownElapsed()) {
        final parked = _coldFailure;
        if (parked != null) return Future.error(parked);
      }
      return _startRefresh();
    }
    final loadedAt = _loadedAt!;
    if (_now().difference(loadedAt) >= ttl && _cooldownElapsed()) {
      return _startRefresh(); // lazy TTL refresh (serve-stale on failure)
    }
    return Future.value(set);
  }

  /// The refresh future for an unknown-`kid` miss, or `null` when the cooldown
  /// forbids a new fetch and none is already running.
  Future<JwkSet>? _refreshForMiss() {
    if (_inFlight != null) return _inFlight; // join whatever is running
    if (!_cooldownElapsed()) return null; // cooling down: immediate miss
    return _startRefresh();
  }

  bool _cooldownElapsed() {
    final last = _lastRefreshAt;
    return last == null || _now().difference(last) >= minRefreshInterval;
  }

  /// Starts (or joins) a single fetch. Records the throttle timestamp for every
  /// non-cold refresh, so the cold initial load never counts against the first
  /// miss's cooldown.
  Future<JwkSet> _startRefresh() {
    final inflight = _inFlight;
    if (inflight != null) return inflight;
    if (_set != null) _lastRefreshAt = _now();
    final future = _fetchParseStore();
    _inFlight = future.whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  /// Fetches, parses, and stores a fresh set — or, on failure with a set already
  /// cached, serves that stale set. A cold failure throws [JwksUnavailable]
  /// (or, for a trust failure, [JwksDiscoveryException]).
  Future<JwkSet> _fetchParseStore() async {
    final Uri jwksUri;
    try {
      jwksUri = await _resolveJwksUri();
    } on JwksDiscoveryException catch (e) {
      // A trust/config failure (issuer mismatch, malformed discovery doc,
      // plaintext discovered jwks_uri) is never masked by serving stale keys and
      // never wrapped — it propagates. When cold, still record it so a
      // persistently bad discovery doc is not re-fetched once per request.
      if (_set == null) _recordColdFailure(e);
      rethrow;
    } on Exception catch (e) {
      final stale = _set;
      if (stale != null) return stale;
      throw _recordColdFailure(
        JwksUnavailable('OIDC discovery failed for issuer "$issuer"', cause: e),
      );
    }

    final String body;
    try {
      body = await _fetch(jwksUri);
    } on Exception catch (e) {
      final stale = _set;
      if (stale != null) return stale;
      throw _recordColdFailure(
        JwksUnavailable('failed to fetch JWKS from $jwksUri', cause: e),
      );
    }

    final JwkSet parsed;
    try {
      parsed = JwkSet.parse(body);
    } on JwksMalformed catch (e) {
      final stale = _set;
      if (stale != null) return stale;
      throw _recordColdFailure(
        JwksUnavailable('JWKS document from $jwksUri is malformed', cause: e),
      );
    }

    // Preserve Jwk identity for keys unchanged across the refresh (see the seam
    // contract), then swap the cache to the fresh view wholesale — a key that
    // has left the JWKS stops verifying the moment this set is stored.
    final reconciled = parsed.reconcileWith(_set);
    _set = reconciled;
    _loadedAt = _now();
    _coldFailure = null; // a healthy load clears any parked cold failure
    return reconciled;
  }

  /// Records a *cold* refresh failure so reads within [minRefreshInterval]
  /// re-surface it without another fetch: stamps the attempt time (engaging the
  /// cooldown the cold path is otherwise exempt from) and parks the cause.
  /// Returns [error] so a caller can `throw _recordColdFailure(...)`.
  T _recordColdFailure<T extends Exception>(T error) {
    _lastRefreshAt = _now();
    _coldFailure = error;
    return error;
  }

  /// The `jwks_uri`, running OIDC Discovery once if it was not given directly.
  Future<Uri> _resolveJwksUri() async {
    final known = _jwksUri;
    if (known != null) return known;

    final configuredIssuer = issuer!;
    final discoveryUri = _discoveryUri(configuredIssuer);
    final body = await _fetch(discoveryUri);

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw JwksDiscoveryException(
        'OIDC discovery document from $discoveryUri is not valid JSON: '
        '${e.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw JwksDiscoveryException(
        'OIDC discovery document from $discoveryUri is not a JSON object',
      );
    }
    final docIssuer = decoded['issuer'];
    if (docIssuer != configuredIssuer) {
      throw JwksDiscoveryException(
        'OIDC discovery "issuer" '
        '${docIssuer is String ? '"$docIssuer"' : '($docIssuer)'} does not '
        'equal the configured issuer "$configuredIssuer"',
      );
    }
    final ju = decoded['jwks_uri'];
    if (ju is! String) {
      throw JwksDiscoveryException(
        'OIDC discovery document from $discoveryUri has no string "jwks_uri"',
      );
    }
    final Uri resolved;
    try {
      resolved = Uri.parse(ju);
    } on FormatException catch (e) {
      // An unparsable jwks_uri is a bad discovery document, not a transport
      // outage — keep it inside the discovery error contract rather than let a
      // raw FormatException escape.
      throw JwksDiscoveryException(
        'OIDC discovery document from $discoveryUri has an invalid "jwks_uri" '
        '"$ju": ${e.message}',
      );
    }
    // A plaintext jwks_uri smuggled into the discovery document is exactly the
    // MITM this source refuses: a discovered http:// endpoint (non-loopback) is
    // a trust failure, kept inside the discovery-error contract.
    if (!_isSecureTransport(resolved)) {
      throw JwksDiscoveryException(
        'OIDC discovery document from $discoveryUri has a non-https "jwks_uri" '
        '"$resolved"; plaintext transport is refused except to a loopback host',
      );
    }
    _jwksUri = resolved;
    return resolved;
  }

  /// The hard upper bound on a single fetched body (discovery or JWKS), in
  /// bytes. A real JWKS is a few KiB; 1 MiB is orders of magnitude of headroom
  /// while still denying an endpoint the ability to stream an unbounded body
  /// into memory under only the coarse total timeout.
  static const int _maxResponseBytes = 1024 * 1024;

  /// Parses an issuer identifier to a [Uri] for the transport-security check.
  /// An issuer that is not a parseable absolute URL yields a scheme-less [Uri]
  /// that [_requireSecureUrl] then rejects — a loud, correct construction error.
  static Uri _parseIssuer(String issuer) {
    try {
      return Uri.parse(issuer);
    } on FormatException {
      throw ArgumentError.value(issuer, 'issuer', 'is not a valid URL');
    }
  }

  /// Throws [ArgumentError] unless [url] is an acceptable transport (see
  /// [_isSecureTransport]). Used for construction-time (programmer-supplied)
  /// URLs; a discovery-supplied URL uses [JwksDiscoveryException] instead.
  static void _requireSecureUrl(Uri url, String name) {
    if (_isSecureTransport(url)) return;
    throw ArgumentError.value(
      url.toString(),
      name,
      'must use https (RFC 8414 §2 requires an https issuer); plaintext http is '
      'permitted only to a loopback host (localhost, 127.0.0.0/8, ::1)',
    );
  }

  /// Whether [url] may be fetched: `https` always, `http` only to a loopback
  /// host (no on-path attacker exists on loopback), any other scheme never.
  static bool _isSecureTransport(Uri url) {
    if (url.isScheme('https')) return true;
    if (url.isScheme('http')) return _isLoopbackHost(url.host);
    return false;
  }

  /// Whether [host] is a loopback address — `localhost`, an IPv4 `127.0.0.0/8`
  /// address, or IPv6 `::1`. [Uri.host] returns IPv6 hosts without brackets, so
  /// a bare `::1` parses correctly.
  static bool _isLoopbackHost(String host) {
    if (host == 'localhost') return true;
    final address = InternetAddress.tryParse(host);
    return address != null && address.isLoopback;
  }

  static Uri _discoveryUri(String issuer) {
    // OIDC Discovery appends the well-known path to the issuer, preserving any
    // path component of the issuer (RFC 8414 §3). Trim one trailing slash so the
    // join produces exactly one separator.
    final base = issuer.endsWith('/')
        ? issuer.substring(0, issuer.length - 1)
        : issuer;
    return Uri.parse('$base/.well-known/openid-configuration');
  }

  static Future<String> _defaultFetch(
    Uri url,
    Duration connectTimeout,
    Duration totalTimeout,
  ) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final request = await client.getUrl(url).timeout(totalTimeout);
      final response = await request.close().timeout(totalTimeout);
      if (response.statusCode != HttpStatus.ok) {
        // Drain so the connection can be reused/closed cleanly, then fail.
        await response.drain<void>();
        throw HttpException(
          'JWKS endpoint returned HTTP ${response.statusCode}',
          uri: url,
        );
      }
      // A declared Content-Length over the cap fails fast without reading a
      // byte; the streaming check below is the authority, since Content-Length
      // may be absent (-1, chunked) or a lie.
      final declared = response.contentLength;
      if (declared > _maxResponseBytes) {
        await response.drain<void>();
        throw HttpException(
          'response Content-Length $declared exceeds the $_maxResponseBytes '
          'byte cap',
          uri: url,
        );
      }
      final bytes = await _readCapped(response, url).timeout(totalTimeout);
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }

  /// Reads [response] into memory, aborting once the accumulated bytes exceed
  /// [_maxResponseBytes]. Throwing out of the `await for` cancels the
  /// subscription, so an oversized body stops streaming immediately rather than
  /// being buffered in full and rejected after the fact.
  static Future<List<int>> _readCapped(
    Stream<List<int>> response,
    Uri url,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > _maxResponseBytes) {
        throw HttpException(
          'response exceeded the $_maxResponseBytes byte cap',
          uri: url,
        );
      }
    }
    return builder.takeBytes();
  }
}

/// OIDC Discovery produced an untrustworthy or unusable result: the discovery
/// document's `issuer` did not match the configured issuer, or the document was
/// not the expected shape. A **trust/configuration** failure, kept distinct from
/// [JwksUnavailable] (a transport outage) and never a [JwtRejection] (it is not
/// about a token). It is never masked by serving stale keys.
final class JwksDiscoveryException implements Exception {
  const JwksDiscoveryException(this.message);

  /// A human-readable explanation.
  final String message;

  @override
  String toString() => 'JwksDiscoveryException: $message';
}

/// The [JwtUnknownKey] message for a header that resolved to no key.
String _missMessage(JoseHeader header, JwkSet set) {
  final kid = header.kid;
  if (kid != null) {
    return 'no key in the JWKS matches kid "$kid"';
  }
  return 'token has no "kid" and the JWKS does not hold exactly one usable key '
      '(${set.keys.length} present)';
}
