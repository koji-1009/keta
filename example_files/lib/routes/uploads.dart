import 'package:keta/keta.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/user_dto.dart';
import 'package:keta_multipart/keta_multipart.dart';
import 'package:keta_openapi/keta_openapi.dart';

const postDoc = RouteDoc(
  summary: 'Accept a multipart/form-data upload',
  requestBody: uploadFormSchema,
  requestBodyType: 'multipart/form-data',
);

/// Streams the parts once, buffering small text fields and reporting file sizes
/// without holding the upload in memory. Persistence would be the app's job.
Future<Response> post(Context<Env> c) async {
  final fields = <String, String>{};
  final files = <Map<String, Object?>>[];
  await for (final part in parts(c)) {
    if (part.filename != null) {
      final bytes = await part.bytes();
      files.add({
        'field': part.name,
        'filename': part.filename,
        'size': bytes.length,
      });
    } else {
      fields[part.name ?? ''] = await part.text();
    }
  }
  return c.json({'fields': fields, 'files': files});
}
