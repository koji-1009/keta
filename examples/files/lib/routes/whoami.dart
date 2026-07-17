import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/auth.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';

final exported = Exported<Env>(
  get: Serve(
    // The other half of authentication: the gate put the caller in the request
    // store, and this reads it back with the same typed Key.
    (c) {
      final who = c.get(principal);
      return c.json({'id': who.id, 'admin': who.admin});
    },
    // `security: [bearer]` is declared, not inherited: `c.get` above asserts a
    // principal is present, and only the bearer verifier sets one.
    doc: const RouteDoc(
      success: Success(),
      summary: 'The authenticated caller',
      security: [bearer],
    ),
  ),
);
