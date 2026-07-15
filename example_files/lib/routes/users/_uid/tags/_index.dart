import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';

/// `/users/:uid/tags/:index` — four directories deep, two of them captures.
///
/// The tree says *where*: `_uid` and `_index` are the parameters, and their
/// names come from the file's own location. The file says *what*: `index` is an
/// integer. Without that the document would say string — the fidelity the
/// string routing syntax cannot reach, since `:index` has no vocabulary for a
/// type. A misspelling here is an unknown named argument, not a contract that
/// quietly starts lying.
final exported = Exported<Env>(
  [
    Get((c) async {
      final rows = await c.env.db.reader.query(
        'select tags from users where id = ?',
        [c.param<String>('uid')],
      );
      if (rows.isEmpty) throw const NotFound('user not found');
      final tags = (rows.first['tags'] as String).split(',');
      final index = c.param<int>('index');
      if (index < 0 || index >= tags.length) {
        throw const NotFound('tag index out of range');
      }
      return c.json({'tag': tags[index]});
    }),
  ],
  captures: {'index': integer},
);
