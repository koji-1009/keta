import 'package:keta/keta.dart';

/// This reference only needs a logger — no database — so Env implements just
/// [HasLog]. Auth is orthogonal to persistence.
class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;

  static Future<Env> boot() async => Env(StdoutLog());
}
