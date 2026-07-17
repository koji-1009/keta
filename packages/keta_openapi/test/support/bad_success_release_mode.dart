// A standalone entrypoint spawned as a subprocess by
// openapi_generation_test.dart to prove that the `Success.status` invariant
// is a hard error at emit time, not merely the constructor's `assert`.
//
// `assert` is only checked when assertions are enabled; `dart test` enables
// them by default, so a normal in-process test can never construct a bad
// `Success` — the assert fires first. `dart run` (like a release binary) runs
// with assertions off by default, which is exactly the release-build scenario
// the guard in openapi.dart exists for, so this script is exercised that way.
//
// The StateError this is expected to raise is left uncaught (the package's
// `avoid_catching_errors` posture): the test asserts on the subprocess's
// stderr and exit code instead of a message printed from inside a `catch`.
library;

import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

class _Env {}

void main() {
  // Not `const Success(...)`: the const evaluator always checks `assert` at
  // compile time regardless of the runtime flag, so only a plain runtime
  // constructor call can reach OpenApi.fromRoutes with the assert disabled.
  final success = Success(status: 500);
  final app = App<_Env>()
    ..get('/x', (c) => c.text('x'), doc: RouteDoc(success: success));
  OpenApi.fromRoutes(app.routes);
}
