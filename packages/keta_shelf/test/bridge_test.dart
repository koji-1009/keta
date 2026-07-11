import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_shelf/keta_shelf.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

class Env {}

void main() {
  test('ketaToShelf serves a keta app as a shelf handler', () async {
    final app = App<Env>()..use(recover());
    app.get('/hello/:who', (c) => c.json({'hello': c.param<String>('who')}));

    final handler = ketaToShelf(app, Env());
    final response = await handler(
        shelf.Request('GET', Uri.parse('http://localhost/hello/shelf')));

    expect(response.statusCode, 200);
    expect(await response.readAsString(), '{"hello":"shelf"}');
  });

  test('ketaToShelf maps a keta 404 through', () async {
    final handler = ketaToShelf(App<Env>(), Env());
    final response =
        await handler(shelf.Request('GET', Uri.parse('http://localhost/nope')));
    expect(response.statusCode, 404);
  });

  test('shelfToKeta runs a shelf handler inside a keta route', () async {
    shelf.Response shelfHandler(shelf.Request request) =>
        shelf.Response.ok('hi from shelf via ${request.method}');

    final app = App<Env>();
    app.get('/bridge', shelfToKeta(shelfHandler));
    final client = TestClient(app, Env());

    final res = await client.get('/bridge');
    expect(res.status, 200);
    expect(res.text(), 'hi from shelf via GET');
  });

  test('shelfToKeta forwards the request body', () async {
    Future<shelf.Response> echo(shelf.Request request) async =>
        shelf.Response.ok('echo:${await request.readAsString()}');

    final app = App<Env>();
    app.post('/echo', shelfToKeta(echo));
    final client = TestClient(app, Env());

    final res = await client.post('/echo', json: {'a': 1});
    expect(res.text(), 'echo:{"a":1}');
  });
}
