import 'dart:io';

import 'package:keta_auth_example/app.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// Emits the OpenAPI document to stdout. The `/admin` operation carries its
/// `security: [{bearer: []}]`, an automatic 401, and a `bearer` entry under
/// `components/securitySchemes` — all from the one route declaration.
///
///   dart run tool/openapi.dart > openapi.yaml
void main() {
  final spec = OpenApi.fromRoutes(
    buildApp().routes,
    title: 'keta auth example',
    version: '0.1.0',
  );
  stdout.write(spec.toYaml());
}
