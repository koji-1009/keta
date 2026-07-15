import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/auth.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';

final exported = Exported<Env>([const Get(_whoami, doc: _whoamiDoc)]);

/// `security: [bearer]` is declared, not inherited: `c.get` below asserts a
/// principal is present, and only the bearer verifier sets one.
const _whoamiDoc = RouteDoc(
  summary: 'The authenticated caller',
  security: [bearer],
);

/// The other half of authentication: the gate put the caller in the request
/// store, and this reads it back with the same typed Key.
Response _whoami(Context<Env> c) {
  final who = c.get(principal);
  return c.json({'id': who.id, 'admin': who.admin});
}
