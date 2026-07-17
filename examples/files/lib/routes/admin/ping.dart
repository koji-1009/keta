import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/auth.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/admin/ping` — a directory is just a path segment. Authorization is no
/// longer inlined here: `routes/admin/_middleware.dart` scopes `requireAdmin()`
/// over this whole subtree, the same "who are you" (gate) vs. "may you"
/// (middleware) split `../register` makes with `app.group('/admin').use(...)`.
final exported = Exported<Env>(
  get: Serve(
    (c) => c.text('pong'),
    // The 403 is part of the contract, so it is declared: it comes from the
    // admin-scope middleware, not from the security gate, and a status the
    // gate never produces still has to reach the document.
    doc: const RouteDoc(
      success: Success(),
      summary: 'Admin-only liveness check',
      failureResponses: {403: errorSchema},
    ),
  ),
);
