/// Owns the data-shaped path form (a prebuilt List of LiteralSegment/
/// CaptureSegment): it binds and reads via c.param like any path, carries the
/// declared capture schema into OpenAPI, has unbounded arity, 400s a bad value,
/// and rejects a non-path argument.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

class Env {}

void main() {
  // A path can be a shape that is data: the parts already built, rather than a
  // chain of segments()/capture() calls written out. This is what a file tree
  // denotes — and the whole reason file-convention routing can carry types at
  // all, since the string syntax has no vocabulary for one.

  test('segments bind like any other path, and c.param reads them', () async {
    final app = App<Env>()
      ..get(
        [
          const LiteralSegment('users'),
          CaptureSegment(string('uid')),
          const LiteralSegment('tags'),
          CaptureSegment(integer('index')),
        ],
        (c) =>
            c.json({'uid': c.param<String>('uid'), 'i': c.param<int>('index')}),
      );

    final r = await TestClient(app, Env()).get('/users/ada/tags/7');
    expect(r.json(), {'uid': 'ada', 'i': 7});
  });

  test('the declared capture reaches OpenAPI, unlike the string syntax', () {
    final data = App<Env>()
      ..get([
        const LiteralSegment('u'),
        CaptureSegment(integer('id')),
      ], (c) => c.text('x'));
    final str = App<Env>()..get('/u/:id', (c) => c.text('x'));

    Object? schemaOf(App<Env> app) =>
        (app.routes.single.segments[1] as CaptureSegment).capture.schema;

    expect(schemaOf(data), {'type': 'integer'});
    // The contrast that motivates this: ':id' can only ever be a string.
    expect(schemaOf(str), {'type': 'string'});
  });

  test('arity is unbounded, unlike the written chain', () async {
    // root.capture()... runs out at four; a tree ten deep must still route.
    final app = App<Env>()
      ..get([
        for (var i = 0; i < 10; i++) CaptureSegment(integer('p$i')),
      ], (c) => c.text('${c.param<int>('p9')}'));

    final r = await TestClient(app, Env()).get('/0/1/2/3/4/5/6/7/8/9');
    expect(r.text(), '9');
  });

  test('a bad value is a 400, exactly as a written capture would be', () async {
    final app = App<Env>()
      ..get([
        const LiteralSegment('u'),
        CaptureSegment(integer('id')),
      ], (c) => c.text('${c.param<int>('id')}'));

    expect((await TestClient(app, Env()).get('/u/abc')).status, 400);
  });

  test('a non-path argument is still rejected', () {
    expect(
      () => App<Env>().get(42, (c) => c.text('x')),
      throwsA(isA<ArgumentError>()),
    );
  });
}
