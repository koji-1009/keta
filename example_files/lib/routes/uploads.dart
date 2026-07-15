import 'package:keta/keta.dart';
import 'package:keta_multipart/keta_multipart.dart';
import 'package:keta_openapi/keta_openapi.dart';

import '../env.dart';
import '../user_dto.dart';

/// A route file added on its own — `dart run keta_files:sync` wires it into the
/// manifest. A multipart upload streamed through keta_multipart.
void register(App<Env> app) {
  app.post(
    '/uploads',
    (c) async {
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
    },
    doc: const RouteDoc(
      summary: 'Accept a multipart/form-data upload',
      requestBody: uploadFormSchema,
      requestBodyType: 'multipart/form-data',
    ),
  );
}
