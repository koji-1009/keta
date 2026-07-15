import 'package:keta/keta.dart';
import 'package:keta_files_example/env.dart';

/// `/users/:uid/tags/:index` — four directories deep, two of them captures.
///
/// The tree says *where*: `_uid` and `_index` are the parameters, and their
/// names are established by the file's own location. This says *what*: `index`
/// is an integer. Without the declaration it would be a string, and the OpenAPI
/// document would say so — which is exactly the fidelity the string routing
/// syntax cannot reach, since `:index` has no vocabulary for a type.
const captures = {'index': integer};

Future<Response> get(Context<Env> c) async {
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
}
