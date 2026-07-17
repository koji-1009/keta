import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'auth.dart';
import 'env.dart';

/// A public route, a bearer-secured `/admin` subtree, and a cookie-session
/// flow (`/login`, `/me`, `/logout`) that is the same gate as `/admin` with a
/// different verifier. Security is declared on the route
/// (`RouteDoc(security: [bearer])` or `[cookieAuth]`) and enforced by a
/// single upstream `enforceSecurity` gate — the declaration drives the
/// OpenAPI output, the runtime 401, and (via scaffold) the contract test.
/// Authorization (the role guard → 403) stays ordinary app middleware.
App<Env> buildApp() {
  final app = App<Env>()
    ..use(recover())
    ..use(enforceSecurity(securityPolicy));

  // `security: const []` is not "no opinion" — it is "public", overriding the
  // secure-by-default global (`securityPolicy.defaults`). A route that simply
  // omitted RouteDoc entirely would inherit that default instead and 401.
  app.get(
    '/public',
    (c) => c.text('anyone can read this'),
    doc: const RouteDoc(success: Success(), summary: 'Public', security: []),
  );

  app.group('/admin')
    ..use(requireRole('admin'))
    ..get(
      '/whoami',
      (c) => c.json({'role': c.get(authRole)}),
      doc: const RouteDoc(
        success: Success(),
        security: [bearer],
        summary: 'The caller identity',
      ),
    );

  // `/login` mints the session, `/me` and `/logout` spend it — the same
  // three-step shape as the bearer flow above, just with a `Set-Cookie`
  // instead of a token handed back out-of-band. `security: []`: logging in
  // is how a caller becomes authenticated, so it cannot itself require
  // authentication.
  app.post(
    '/login',
    (c) async {
      final body = await c.body();
      final creds = body is Map ? body : const <String, Object?>{};
      final username = creds['username'] as String?;
      final password = creds['password'] as String?;
      final sid = username == null || password == null
          ? null
          : login(c.env, username, password);
      if (sid == null) throw const Unauthorized('invalid credentials');
      // httpOnly: no script can read the session id (contains XSS from
      // turning into session hijack). sameSite: lax: still rides a top-level
      // cross-site navigation (a followed link) but never a cross-site POST,
      // which is CSRF containment without a separate token. secure: true is
      // deliberately NOT set here — this demo serves plain HTTP, and a
      // browser drops a Secure cookie set over an insecure connection
      // outright. Production over TLS must add secure: true; SameSite.none
      // would require it by construction (SetCookie enforces that pairing at
      // construction, so the mistake of one without the other is
      // unrepresentable).
      final cookie = SetCookie(
        'sid',
        sid,
        httpOnly: true,
        sameSite: SameSite.lax,
        maxAge: const Duration(hours: 1),
      );
      return c.json(
        {'role': username},
        headers: {
          'set-cookie': [cookie.toHeaderValue()],
        },
      );
    },
    doc: const RouteDoc(
      success: Success(),
      summary: 'Log in, starting a cookie session',
      security: [],
    ),
  );

  app.get(
    '/me',
    (c) => c.json({'role': c.get(authRole)}),
    doc: const RouteDoc(
      success: Success(),
      security: [cookieAuth],
      summary: 'The session caller identity',
    ),
  );

  app.post(
    '/logout',
    (c) {
      logout(c.env, c.cookie('sid'));
      // Expiring a cookie is Max-Age=0 (or an Expires in the past) sent under
      // the same name/path/domain as the one that set it — the browser
      // matches the cookie to delete by that identity, not by value, so the
      // value carried here is irrelevant and left empty.
      final expired = SetCookie(
        'sid',
        '',
        maxAge: Duration.zero,
        httpOnly: true,
        sameSite: SameSite.lax,
      );
      return c.json(
        {'ok': true},
        headers: {
          'set-cookie': [expired.toHeaderValue()],
        },
      );
    },
    doc: const RouteDoc(
      success: Success(),
      security: [cookieAuth],
      summary: 'Log out, ending the cookie session',
    ),
  );

  return app;
}
