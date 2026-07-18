import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:keta/keta.dart';
import 'package:keta_bus/keta_bus.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'env.dart';

/// The authenticated caller's role, set by whichever verifier admitted the
/// request (bearer or cookie session alike) and read downstream with
/// `c.tryGet(authRole)`.
final authRole = Key<String>('auth.role');

/// The live session id, set by the cookie verifier alongside [authRole] so a
/// handler that needs the id itself (only `/me/events` does — see
/// [sessionEvents]) does not have to re-read and re-trust the `Cookie` header
/// a second time.
final sessionId = Key<String>('auth.sid');

// A stand-in token table. A real app verifies a JWT or a session here.
const _tokens = {'admin-token': 'admin', 'member-token': 'member'};

/// Demo login credentials for the cookie-session flow below, keyed by the
/// same roles `_tokens` grants over bearer — a real app checks a password
/// hash against a user store here; this table is the same kind of stand-in
/// `_tokens` is for bearer, just reached by `/login` instead of a header.
const _credentials = {'admin': 'admin-pass', 'member': 'member-pass'};

/// keta_openapi ships `bearer` and `apiKey`; a cookie-carried credential is
/// documented in OpenAPI the same way `apiKey` is — a named location, not a
/// bearer scheme — so this reference mints its own scheme rather than
/// stretching `apiKey`'s "header" semantics to fit a cookie. `in: 'cookie'` is
/// exactly what OpenAPI's `apiKey` type provides for this case.
const cookieAuth = SecurityScheme('cookieAuth', {
  'type': 'apiKey',
  'in': 'cookie',
  'name': 'sid',
});

final _sessionRandom = Random.secure();

/// A random session id: 16 secure-random bytes as lowercase hex, the same
/// idiom `App._reqId` uses for request ids. Unguessable is the whole point —
/// a session store keyed by anything predictable is a hijack waiting to
/// happen.
String _newSessionId() {
  final bytes = List<int>.generate(16, (_) => _sessionRandom.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Verifies [username]/[password] against the demo credential table and, on
/// success, mints a session id and stores `sid -> role` in [env]'s store —
/// the credential check and the session-store write both stay app code, same
/// as the bearer token table above. Returns the new session id, or null on
/// invalid credentials, for `/login` to turn into a cookie or a 401.
String? login(Env env, String username, String password) {
  if (_credentials[username] != password) return null;
  final sid = _newSessionId();
  env.sessions[sid] = username;
  return sid;
}

/// The bus topic one live session's revocation notices ride on — one topic
/// per session id, so a notice reaches exactly the one open `/me/events`
/// stream it concerns and no other session's.
String sessionTopic(String sid) => 'session:$sid';

/// Ends a session by removing [sid] from [env]'s store and publishing a
/// revocation notice on its topic — the pattern this file exists to
/// demonstrate: "a session is revoked → a notice goes out on the bus → the
/// server closes the affected live connection from its side" (see
/// [sessionEvents], which is the subscriber side of this same publish). A
/// null or already-removed [sid] is not an error — logging out twice is still
/// logged out, and publishing to a topic nobody is listening on is simply
/// dropped (keta_bus's at-most-once contract), not a failure.
void logout(Env env, String? sid) {
  if (sid == null) return;
  env.sessions.remove(sid);
  env.bus.publish(sessionTopic(sid), {'kind': 'revoked'});
}

/// The JSON shape of one `/me/events` event — `revoked` is the only kind this
/// demo ever emits (there is no other session-status event to show), but the
/// object shape leaves room for a real app to add more without breaking this
/// one's meaning.
const sessionEventSchema = Schema('SessionEvent', {
  'type': 'object',
  'required': ['kind'],
  'properties': {
    'kind': {
      'type': 'string',
      'enum': ['revoked'],
    },
  },
});

/// The live feed `/me/events` streams: every notice published to [sid]'s
/// topic on [bus], rendered as an SSE event, ending itself right after a
/// `revoked` one.
///
/// Built on an explicit [StreamController], not an `async*` generator
/// wrapping `await for` — the same choice keta's own `c.sse` implementation
/// makes, and for the same reason (see `packages/keta/lib/src/sse.dart`'s doc
/// comment on `_sseBody`): a generator suspended inside `await for` on
/// another stream does not respond to its OWN subscription being cancelled
/// until it next resumes (a genuine Dart behavior, confirmed by hand — not a
/// hypothetical). Concretely, that means if `/me/events`' client disconnected
/// normally — never revoked — `c.sse` cancelling the async* version's
/// subscription would never actually detach it from `bus.subscribe(...)`: the
/// generator stays parked in `await for`, forever holding a listener on that
/// session's topic. A [StreamController] with an explicit `onCancel` has a
/// single, deterministic cleanup point instead: cancelling the subscription
/// this returns synchronously cancels [sub] below, no generator involved.
///
/// `revoked` still ends the stream from the SERVER's side, which is the
/// pattern this file exists to show: the handler yields the event, then
/// closes the controller in the very same callback — the client never has to
/// notice anything or hang up on its own.
Stream<SseEvent> sessionEvents(Bus bus, String sid) {
  late final StreamController<SseEvent> controller;
  StreamSubscription<Object?>? sub;
  controller = StreamController<SseEvent>(
    onListen: () {
      sub = bus.subscribe(sessionTopic(sid)).listen((raw) {
        final msg = raw as Map<String, Object?>;
        controller.add(SseEvent(jsonEncode(msg), event: msg['kind'] as String));
        if (msg['kind'] == 'revoked') controller.close();
      }, onDone: controller.close);
    },
    onCancel: () => sub?.cancel(),
  );
  return controller.stream;
}

/// The security policy, wired once via `enforceSecurity`. keta owns only the
/// plumbing that matches a route's declared schemes to these verifiers; the
/// credential check itself is app code, so "keta ships no auth" holds. The
/// bearer verifier resolves the token to a role; the cookie verifier resolves
/// a session id the same way. Both store the result for the role guard
/// downstream — same side-effect pattern, two different credential shapes.
///
/// `defaults: [bearer]` makes a route that declares no security fail closed —
/// forgetting to think about auth is a 401, not a silent public route. A
/// route meant to be public says so explicitly (`RouteDoc(security: const
/// [])`), which is what `/public` does.
final securityPolicy = SecurityPolicy<Env>(
  defaults: const [bearer],
  verifiers: {
    'bearer': (c) {
      final header = c.header('authorization') ?? '';
      const scheme = 'Bearer ';
      final token = header.startsWith(scheme)
          ? header.substring(scheme.length)
          : '';
      final role = _tokens[token];
      if (role == null) return false;
      c.set(authRole, role);
      return true;
    },
    // Same side-effect pattern as bearer above: on success, resolve to a role
    // and c.set it for the role guard. The only difference is where the
    // credential travels (a `Cookie` header, parsed by `c.cookie`) and where
    // it resolves (the app-owned session store on Env, not a fixed table).
    cookieAuth.name: (c) {
      final sid = c.cookie('sid');
      if (sid == null) return false;
      final role = c.env.sessions[sid];
      if (role == null) return false;
      c.set(authRole, role);
      c.set(sessionId, sid);
      return true;
    },
  },
);

/// Requires the authenticated caller to hold [required]; otherwise 403
/// ([Forbidden]). Runs after `enforceSecurity` has set the role.
///
/// [authRole] is read with `tryGet`, not `get`: an unset role is an expected
/// authentication outcome (a scheme admitted the request without one, or this
/// middleware ends up on a route reachable through one that doesn't set it),
/// not a programming defect — it must 403 here, not crash the process with a
/// 500 from `get`'s `StateError`. Absent role matches no required role, and
/// that is the whole rule.
Middleware<E> requireRole<E>(String required) => (c, next) {
  if (c.tryGet(authRole) != required) {
    throw Forbidden('requires the "$required" role');
  }
  return next(c);
};
