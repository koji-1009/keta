import 'dart:io';

import 'package:keta_auth_example/app.dart';

/// Emits the OpenAPI document to stdout. The `/admin` operation carries its
/// `security: [{bearer: []}]`, an automatic 401, and a `bearer` entry under
/// `components/securitySchemes` — all from the one route declaration.
///
///   dart run tool/openapi.dart > openapi.yaml
void main() {
  final spec = buildOpenApi();
  stdout.write(spec.toYaml());
}
