import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/auth.dart';
import 'package:keta_files_example/env.dart';

/// Scopes `requireAdmin()` over every route under `/admin` — the file-based
/// answer to `../register`'s `app.group('/admin').use(requireAdmin())`, with
/// this directory standing in for the `/admin` prefix. Nothing in this file
/// names the scope; `routes/admin/` does.
final scoped = ScopedMiddleware<Env>([requireAdmin()]);
