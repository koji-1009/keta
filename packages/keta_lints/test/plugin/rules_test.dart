// test_reflective_loader requires test methods to be named `test_...`.
// ignore_for_file: non_constant_identifier_names

// Analyzer-plugin rule tests. Each proves the wired rule fires on a fixture,
// reports the keta rule name as the diagnostic code at the right source range,
// and carries the `[<16-hex-id>] <message>` the `keta_lints:check` CLI produces
// for the same source — the spec's "identical in IDE and CLI" principle.
//
// The rules are syntactic, so fixtures reference framework types only through
// tiny inline stubs (or `dynamic`), keeping each fixture free of unrelated
// analyzer diagnostics.
library;

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:keta_lints/keta_lints.dart'
    show diagnosticId, packageRelativePath;
import 'package:keta_lints/src/plugin/rules.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(KetaRouteRuleTest);
    defineReflectiveTests(KetaQueryRuleTest);
    defineReflectiveTests(KetaCanonicalRuleTest);
    defineReflectiveTests(KetaTxOrderRuleTest);
    defineReflectiveTests(KetaKeyRuleTest);
    defineReflectiveTests(KetaInternalAwaitRuleTest);
  });
}

/// Every reported keta message opens with the stable correlation id.
final _idPrefix = RegExp(r'^\[[0-9a-f]{16}\] ');

@reflectiveTest
class KetaRouteRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = KetaRouteRule();
    super.setUp();
  }

  Future<void> test_paramUnknown_fires() async {
    await assertDiagnostics(
      r'''
void f(dynamic app) {
  app.get('/users', (c) {
    c.param('id');
  });
}
''',
      [
        lint(
          60,
          4,
          name: 'keta_param_unknown',
          messageContainsAll: [
            _idPrefix,
            'c.param(\'id\') is not a capture in "/users"',
          ],
        ),
      ],
    );
  }

  Future<void> test_captureUnused_fires() async {
    await assertDiagnostics(
      r'''
void f(dynamic app) {
  app.get('/users/:id', (c) {});
}
''',
      [
        lint(
          32,
          12,
          name: 'keta_capture_unused',
          messageContainsAll: [_idPrefix, 'capture ":id" in "/users/:id"'],
        ),
      ],
    );
  }

  Future<void> test_clean() async {
    await assertNoDiagnostics(r'''
void f(dynamic app) {
  app.get('/users/:id', (c) {
    c.param('id');
  });
}
''');
  }
}

@reflectiveTest
class KetaQueryRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = KetaQueryRule();
    super.setUp();
  }

  static const _stubs = '''
class RouteDoc {
  const RouteDoc({this.query = const []});
  final List<QueryParam> query;
}

class QueryParam {
  const QueryParam(this.name, {this.required = false});
  final String name;
  final bool required;
}
''';

  Future<void> test_undeclared_fires() async {
    await assertDiagnostics(
      '''
$_stubs
void f(dynamic app) {
  app.get('/s', (c) {
    c.query('missing');
  }, doc: RouteDoc(query: [QueryParam('other')]));
}
''',
      [
        lint(
          273,
          9,
          name: 'keta_query_undeclared',
          messageContainsAll: [
            _idPrefix,
            "c.query('missing') is not declared in RouteDoc.query",
          ],
        ),
      ],
    );
  }

  Future<void> test_drift_fires() async {
    await assertDiagnostics(
      '''
$_stubs
void f(dynamic app) {
  app.get('/s', (c) {
    c.tryQuery('page');
  }, doc: RouteDoc(query: [QueryParam('page', required: true)]));
}
''',
      [
        lint(
          276,
          6,
          name: 'keta_query_drift',
          messageContainsAll: [
            _idPrefix,
            'query "page" is declared required but read with tryQuery',
          ],
        ),
      ],
    );
  }

  Future<void> test_clean() async {
    await assertNoDiagnostics('''
$_stubs
void f(dynamic app) {
  app.get('/s', (c) {
    c.query('page');
  }, doc: RouteDoc(query: [QueryParam('page', required: true)]));
}
''');
  }
}

@reflectiveTest
class KetaCanonicalRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = KetaCanonicalRule();
    super.setUp();
  }

  Future<void> test_missing_firesWithExactId() async {
    // The full `[id] message` must equal what the CLI produces for the same
    // file — so compute the id from the SAME normalized key both sides use: the
    // package-relative path, not the analyzer's raw absolute path. This is the
    // portability guarantee (item 1) exercised through the wired plugin.
    final path = convertPath('$testPackageLibPath/test.dart');
    final id = diagnosticId(
      packageRelativePath(path),
      'Point',
      'keta_canonical_missing',
    );
    // A Schema-declared DTO with NEITHER mapper is the missing case (a one-way
    // projection — exactly one mapper — is legitimate and never fires missing).
    // `Schema` is a tiny inline stub so the fixture carries no unrelated
    // analyzer diagnostics, and `Point` stays the first declaration so its name
    // token keeps offset 6.
    await assertDiagnostics(
      r'''
class Point {
  final int x;
  Point({required this.x});
}
const pointSchema = Schema('Point', {'type': 'object', 'properties': {'x': {'type': 'integer'}}});
class Schema {
  const Schema(this.name, this.def);
  final String name;
  final Object def;
}
''',
      [
        lint(
          6,
          5,
          name: 'keta_canonical_missing',
          messageContainsAll: ['[$id] class Point has a Schema constant but'],
        ),
      ],
    );
  }

  Future<void> test_drift_fires() async {
    await assertDiagnostics(
      r'''
class Point {
  final int x;
  final int y;
  Point(this.x, this.y);
  factory Point.fromJson(Map<String, Object?> j) =>
      Point(j['x']! as int, j['y']! as int);
  Map<String, Object?> toJson() => {'x': x};
}
''',
      [
        lint(
          6,
          5,
          name: 'keta_canonical_drift',
          messageContainsAll: [
            _idPrefix,
            'class Point has drifted',
            'fields not in toJson: y',
          ],
        ),
      ],
    );
  }

  Future<void> test_clean() async {
    await assertNoDiagnostics(r'''
class Point {
  final int x;
  Point(this.x);
  factory Point.fromJson(Map<String, Object?> j) => Point(j['x']! as int);
  Map<String, Object?> toJson() => {'x': x};
}
''');
  }

  /// The type-drift finding (keta_type_drift) is wired and reported in the IDE
  /// path exactly like the CLI — the registration parity item 3 requires.
  Future<void> test_typeDrift_fires() async {
    // An `int?` field whose fromJson casts `as int` is an optionality slip:
    // `int` is assignable to the `int?` parameter, so the analyzer sees no
    // static error — yet the cast still throws on an absent key at runtime.
    // The keta rule catches exactly this syntactically.
    await assertDiagnostics(
      r'''
class Point {
  final int? x;
  Point({this.x});
  factory Point.fromJson(Map<String, Object?> j) => Point(x: j['x'] as int);
  Map<String, Object?> toJson() => {if (x != null) 'x': x};
}
''',
      [
        lint(
          6,
          5,
          name: 'keta_type_drift',
          messageContainsAll: [
            _idPrefix,
            'fromJson casts as int but the field is int?',
          ],
        ),
      ],
    );
  }

  /// The `// ignore:` line comment suppresses the diagnostic in the plugin path.
  /// This is exactly why every LintCode is a top-level `const` (a single
  /// instance so suppression can match) — a load-bearing property that had no
  /// coverage until now.
  Future<void> test_lineIgnore_suppresses() async {
    await assertNoDiagnostics(r'''
// ignore: keta_canonical_drift
class Point {
  final int x;
  final int y;
  Point({required this.x, required this.y});
  factory Point.fromJson(Map<String, Object?> j) =>
      Point(x: j['x'] as int, y: j['y'] as int);
  Map<String, Object?> toJson() => {'x': x};
}
''');
  }

  /// The file-level `// ignore_for_file:` form suppresses it too.
  Future<void> test_ignoreForFile_suppresses() async {
    await assertNoDiagnostics(r'''
// ignore_for_file: keta_canonical_drift
class Point {
  final int x;
  final int y;
  Point({required this.x, required this.y});
  factory Point.fromJson(Map<String, Object?> j) =>
      Point(x: j['x'] as int, y: j['y'] as int);
  Map<String, Object?> toJson() => {'x': x};
}
''');
  }
}

@reflectiveTest
class KetaTxOrderRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = KetaTxOrderRule();
    super.setUp();
  }

  Future<void> test_txOutsideRecover_fires() async {
    await assertDiagnostics(
      r'''
dynamic tx() => null;
dynamic recover() => null;
void f(dynamic app) {
  app..use(tx())..use(recover());
}
''',
      [
        lint(
          82,
          4,
          name: 'keta_tx_outside_recover',
          messageContainsAll: [
            _idPrefix,
            'use(tx()) is registered outside use(recover())',
          ],
        ),
      ],
    );
  }

  Future<void> test_clean() async {
    await assertNoDiagnostics(r'''
dynamic tx() => null;
dynamic recover() => null;
void f(dynamic app) {
  app..use(recover())..use(tx());
}
''');
  }
}

@reflectiveTest
class KetaKeyRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = KetaKeyRule();
    super.setUp();
  }

  static const _stubs = '''
class Key<T> {
  Key(this.name);
  final String name;
}
''';

  Future<void> test_inlineKey_inGet_fires() async {
    await assertDiagnostics(
      '''
$_stubs
void f(dynamic c) {
  c.get(Key<String>('reqId'));
}
''',
      [
        lint(
          85,
          20,
          name: 'keta_key_inline',
          messageContainsAll: [
            _idPrefix,
            'Key compares by identity',
            'top-level or static',
          ],
        ),
      ],
    );
  }

  Future<void> test_inlineKey_inSet_fires() async {
    await assertDiagnostics(
      '''
$_stubs
void f(dynamic c) {
  c.set(Key('reqId'), 'v');
}
''',
      [
        lint(85, 12, name: 'keta_key_inline', messageContainsAll: [_idPrefix]),
      ],
    );
  }

  Future<void> test_identifierKey_isClean() async {
    await assertNoDiagnostics('''
$_stubs
final reqIdKey = Key<String>('reqId');
void f(dynamic c) {
  c.get(reqIdKey);
}
''');
  }

  Future<void> test_localVariableKey_isClean() async {
    await assertNoDiagnostics('''
$_stubs
void f(dynamic c) {
  final k = Key('x');
  c.get(k);
}
''');
  }
}

@reflectiveTest
class KetaInternalAwaitRuleTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = KetaInternalAwaitRule();
    super.setUp();
  }

  Future<void> test_await_fires() async {
    await assertDiagnostics(
      r'''
Future<void> f(Future<void> p) async {
  await p;
}
''',
      [
        lint(
          41,
          5,
          name: 'keta_internal_await',
          messageContainsAll: [_idPrefix, 'defeats the synchronous path'],
        ),
      ],
    );
  }

  Future<void> test_allowAwait_isClean() async {
    await assertNoDiagnostics(r'''
Future<void> f(Future<void> p) async {
  await p; // keta:allow-await
}
''');
  }
}
