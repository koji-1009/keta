import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// The environment. This example needs nothing but a log, so [HasLog] is the
/// whole contract — a realtime service with real dependencies would carry them
/// here the way examples/register does.
class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;

  static Future<Env> boot() async => Env(StdoutLog());
}

/// Who the request is. The bearer verifier puts this in the request store on a
/// successful handshake; the handler reads it back with the same typed [Key] —
/// the canonical middleware→handler handoff, exercised here across an upgrade.
final principal = Key<String>('principal');

/// Secure by default: a route that declares nothing inherits [bearer], so
/// forgetting to think about auth fails closed. Read in two places — the
/// document (`OpenApi.fromRoutes(security:)`) and the runtime gate
/// (`SecurityPolicy.defaults`) — so the contract and the guard cannot drift.
const apiDefaults = [bearer];

/// Demo credentials. keta ships no auth; matching a token to a principal is the
/// app's business by design.
const _tokens = {'t-ok': 'ada'};

/// The runtime half of the declaration: app code keta only invokes when a
/// route's declared scheme matches.
SecurityPolicy<Env> securityPolicy() => SecurityPolicy<Env>(
  defaults: apiDefaults,
  verifiers: {
    bearer.name: (c) {
      final header = c.header('authorization');
      if (header == null || !header.startsWith('Bearer ')) return false;
      final who = _tokens[header.substring(7)];
      if (who == null) return false;
      // Authentication only, and the side effect that lets the handler learn
      // who connected without parsing the header a second time.
      c.set(principal, who);
      return true;
    },
  },
);

/// Builds the app. There is deliberately no `cors()` here, and that absence is
/// the whole reason this example exists rather than folding into
/// examples/register: cors() rebuilds every response to merge its headers, and
/// that rebuild does not carry the `Upgrade` value a handshake returns — so a
/// WebSocket behind cors is answered 101 and never actually switches. The
/// security gate, by contrast, composes cleanly in front of an upgrade: because
/// the intent to upgrade is a *returned value*, `enforceSecurity` throws
/// Unauthorized/401 before the `Upgrade` is even built.
App<Env> buildApp() {
  final app = App<Env>()
    ..use(accessLog())
    ..use(recover())
    ..use(enforceSecurity(securityPolicy()));

  // The handshake is an ordinary GET — no new verb — so nothing about routing
  // changes; the upgrade is just the value the handler returns. `onConnected`
  // is handed the switched channel once, and the echo loop it installs lives for
  // the socket's whole lifetime, proving the handshake request does not stay
  // "in flight".
  app.get(
    '/ws/echo',
    (c) {
      // The gate admitted this request, so the principal is present — read it
      // before returning the upgrade value, then greet the client with it once
      // the socket is live. (This runs before the switch; the closure captures
      // the value, not the Context.)
      final who = c.get(principal);
      return Response.upgrade((channel) {
        channel.send('hello $who');
        channel.messages.listen(channel.send);
      });
    },
    // A `SwitchingProtocols` sits parallel to `Success`: it IS the terminal
    // response (a 101, which no `Success` can be — a Success asserts a 2xx), and
    // it carries no body. Documented so the contract names the switch even
    // though OpenAPI has no representation of the WebSocket session that follows.
    // `security: [bearer]` is declared, not inherited, so the automatic 401 the
    // handshake refusal produces is part of the written contract.
    doc: const RouteDoc.upgrade(
      upgrade: SwitchingProtocols(),
      summary: 'Echo WebSocket',
      description:
          'Upgrades to a WebSocket that greets with the caller principal and '
          'echoes every frame back. The bearer gate runs before the upgrade, so '
          'an unauthenticated handshake is refused with 401 rather than '
          'switched.',
      tags: ['ws'],
      operationId: 'echoWebSocket',
      security: [bearer],
    ),
  );
  return app;
}

/// The OpenAPI document for [buildApp], with the same defaults the runtime gate
/// enforces, so the contract test and the emitted file cannot disagree.
OpenApi buildOpenApi() => OpenApi.fromRoutes(
  buildApp().routes,
  title: 'keta websocket example',
  version: '0.1.0',
  security: apiDefaults,
);
