import 'dart:io';

import 'package:keta_files_example/routes.dart';

/// Emits the OpenAPI document to stdout:
///   dart run tool/openapi.dart > openapi.yaml
void main() => stdout.write(buildOpenApi().toYaml());
