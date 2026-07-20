import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/user_dto.dart';
import 'package:keta_multipart/keta_multipart.dart';

final exported = Exported<Env>(
  post: Serve(
    // Streams the parts once, buffering small text fields and reporting file
    // sizes without holding the upload in memory. Persistence is the app's job.
    (c) async {
      final fields = <String, String>{};
      final files = <Map<String, Object?>>[];
      await for (final part in parts(c)) {
        // A form part with no `name` is malformed for a form submission, and the
        // old `part.name ?? ''` silently collapsed every unnamed part onto the
        // one `''` key — the second overwrote the first, losing data with no
        // error. Reject it instead, naming the constraint. (Indexing unnamed
        // parts by position would be the other honest choice; rejecting is the
        // stricter one, and a demo should not invent field names.)
        final name = part.name;
        if (name == null) {
          throw const BadRequest('every multipart part must carry a name');
        }
        if (part.filename != null) {
          final bytes = await part.bytes();
          files.add({
            'field': name,
            'filename': part.filename,
            'size': bytes.length,
          });
        } else {
          fields[name] = await part.text();
        }
      }
      return c.json({'fields': fields, 'files': files});
    },
    doc: const RouteDoc(
      success: Success(),
      summary: 'Accept a multipart/form-data upload',
      requestBody: uploadFormSchema,
      requestBodyType: 'multipart/form-data',
    ),
  ),
);
