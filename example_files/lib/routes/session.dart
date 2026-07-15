import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

import '../auth.dart';
import '../env.dart';

/// Who the caller is, and what that lets them do. One route file = one
/// `register`; keta_files discovers this and wires it into the manifest.
void register(App<Env> app) {
  // The other half of authentication: the gate put the caller in the request
  // store, and the handler reads it back with the same typed Key. Nothing is
  // parsed twice, and the handler cannot see a request the gate did not admit.
  // `security: [bearer]` is declared, not inherited: c.get below asserts a
  // principal is present, and only the bearer verifier sets one. Leaving it to
  // the default would make that assumption true only by accident — add apiKey
  // to apiDefaults and the OR-combining gate would admit a caller with no
  // principal, turning this handler into a 500.
  app.get('/whoami', (c) {
    final who = c.get(principal);
    return c.json({'id': who.id, 'admin': who.admin});
  }, doc: const RouteDoc(summary: 'The authenticated caller', security: [bearer]));

  // Authorization is ordinary middleware, scoped to a group rather than the
  // whole app: `enforceSecurity` answers "who are you", `requireAdmin` answers
  // "may you". Keeping them apart is why 401 and 403 stay distinguishable.
  // The 403 is part of the contract, so it is declared. `responses` is how a
  // status the gate never produces — this one comes from requireAdmin, not
  // enforceSecurity — still reaches the document.
  app
      .group('/admin')
      .use(requireAdmin())
      .get(
        '/ping',
        (c) => c.text('pong'),
        doc: const RouteDoc(
          summary: 'Admin-only liveness check',
          responses: {403: errorSchema},
        ),
      );
}
