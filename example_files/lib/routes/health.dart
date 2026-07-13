import 'package:keta/keta.dart';

import '../env.dart';

/// One route file = one `register`. keta_files discovers this file and wires
/// its registration into the manifest; nothing else imports it.
void register(App<Env> app) {
  app.get('/health', (c) => c.text('ok'));
}
