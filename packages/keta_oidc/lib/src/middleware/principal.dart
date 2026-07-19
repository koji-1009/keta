library;

import 'package:keta/keta.dart';

import '../jwt/claims.dart';

/// The authenticated caller a validated Bearer token represents — what `oidc()`
/// injects into the request [Context] on success, and what a handler reads back
/// via [oidcPrincipal].
///
/// It is a thin, already-validated view over the token: by the time an
/// [OidcPrincipal] exists, the signature, algorithm, issuer, audience, and
/// expiry have all passed. It carries the identity ([subject]), the whole
/// [claims] set for anything else a handler needs, and the [scopes] parsed for
/// authorization.
final class OidcPrincipal {
  const OidcPrincipal({
    required this.subject,
    required this.claims,
    required this.scopes,
  });

  /// Builds a principal from validated [claims], parsing its scopes.
  factory OidcPrincipal.fromClaims(JwtClaims claims) => OidcPrincipal(
    subject: claims.subject,
    claims: claims,
    scopes: parseScopes(claims),
  );

  /// The subject (`sub`) — the stable identifier of the caller — or `null` if
  /// the token carried none. Surfaced, never required: a token without a `sub`
  /// still authenticates (the JWT layer does not demand one), and whether a
  /// missing `sub` matters is the application's call.
  final String? subject;

  /// The full validated claim set, for anything beyond [subject] and [scopes]
  /// (tenant, roles, email, custom claims). Read application claims from
  /// [JwtClaims.raw].
  final JwtClaims claims;

  /// The caller's granted scopes, parsed from the token (see [parseScopes]).
  final Set<String> scopes;
}

/// The [Key] under which `oidc()` binds the [OidcPrincipal] into a request
/// [Context], and under which `requireScopes()` and handlers read it back with
/// `c.get(oidcPrincipal)` / `c.tryGet(oidcPrincipal)`.
///
/// It is a **shared, exported instance** — the identity a `Context` store keys
/// on is this exact object. Never construct a `Key<OidcPrincipal>` inline at a
/// `get`/`set` call site: a fresh `Key` compares unequal to this one and would
/// silently read nothing (the `keta_key_inline` lint exists to catch exactly
/// that mistake). Import and use this instance.
final Key<OidcPrincipal> oidcPrincipal = Key<OidcPrincipal>('oidc.principal');

/// Parses a token's granted scopes as the **union** of two claims major IdPs use
/// interchangeably:
///
/// * `scope` — the RFC 6749 form, a single space-delimited string
///   (`"read write"`);
/// * `scp` — the variant Azure AD and others emit, either a space-delimited
///   string **or** a JSON array of strings.
///
/// Both are read and unioned into one set: if a token carries both (some issuers
/// do), the caller is granted the union rather than one being silently ignored.
/// A value of an unexpected JSON type contributes nothing (it is not a
/// rejection — the token is already validated; an odd scope shape simply yields
/// fewer scopes, so a `requireScopes` gate fails closed with a 403 rather than
/// admitting on a misread).
Set<String> parseScopes(JwtClaims claims) {
  final scopes = <String>{};

  final scope = claims.raw['scope'];
  if (scope is String) {
    scopes.addAll(scope.split(' ').where((s) => s.isNotEmpty));
  }

  final scp = claims.raw['scp'];
  if (scp is String) {
    scopes.addAll(scp.split(' ').where((s) => s.isNotEmpty));
  } else if (scp is List) {
    for (final entry in scp) {
      if (entry is String && entry.isNotEmpty) scopes.add(entry);
    }
  }

  return Set.unmodifiable(scopes);
}
