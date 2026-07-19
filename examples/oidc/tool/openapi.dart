import 'dart:io';

import 'package:keta_oidc_example/app.dart';

/// Emits the OpenAPI document — the code's shadow — to stdout:
///   dart run tool/openapi.dart > openapi.yaml
void main() => stdout.write(buildOpenApi().toYaml());
