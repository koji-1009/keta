import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/auth.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/admin/ping` — a directory is just a path segment.
final exported = Exported<Env>([const Get(_ping, doc: _pingDoc)]);

/// The 403 is part of the contract, so it is declared: it comes from this
/// handler, not from the security gate, and a status the gate never produces
/// still has to reach the document.
const _pingDoc = RouteDoc(
  summary: 'Admin-only liveness check',
  responses: {403: errorSchema},
);

/// Authorization is the handler's or a middleware's business: the gate answers
/// "who are you", this answers "may you". Keeping them apart is why 401 and 403
/// stay distinguishable.
Response _ping(Context<Env> c) {
  final who = c.tryGet(principal);
  if (who == null || !who.admin) throw const Forbidden('admin only');
  return c.text('pong');
}
