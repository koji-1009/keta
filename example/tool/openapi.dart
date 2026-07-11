import 'dart:io';

import 'package:keta_example/app.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// Emits the OpenAPI document — the code's shadow — to stdout:
///   dart run tool/openapi.dart > openapi.yaml
void main() {
  final spec = OpenApi.fromRoutes(
    buildApp().routes,
    title: 'keta example',
    version: '0.1.0',
  );
  stdout.write(spec.toYaml());
}
