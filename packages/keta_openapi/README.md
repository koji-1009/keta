# keta_openapi

Ring 1 of keta: the route-table walk that emits an OpenAPI 3.1 document from a running app's `RouteDoc`/`Schema` declarations. Everything here is **runtime assembly** — plain values read back at emit time. There is no code generation, no `build_runner`, no annotations, and no reflection anywhere in the package.

`Schema`, `RouteDoc`, and the `SecurityPolicy`/`enforceSecurity` runtime gate live in `keta` core, not here — they are the declaration contract, and both boundary validation and the security gate run off them at request time, independent of this package. keta_openapi only *reads* those declarations and projects them one way into a document: `import 'package:keta/keta.dart'` for `Schema`/`RouteDoc`/`listSchema`/`bearer`/`apiKey`/`SecurityPolicy`/`enforceSecurity`; `import 'package:keta_openapi/keta_openapi.dart'` for `OpenApi` alone. Because the contract types don't live here, this package is removable without changing any runtime behavior — no request-handling code depends on it.

## The one-way shadow

Truth flows one way: the running routes and their `RouteDoc`s are the source, and the document is their shadow. `OpenApi.fromRoutes` walks the route table, extracting paths and path parameters mechanically from the route values and bodies/responses from each route's `RouteDoc`; nothing ever flows back — the document never drives the routes, and nothing is inferred from middleware (security, like everything else, travels as declared data). The single escape hatch is `override`, a function that receives the finished document and may rewrite it.

```dart
import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

const userSchema = Schema('User', {
  'type': 'object',
  'required': ['id', 'name'],
  'properties': {
    'id': {'type': 'integer'},
    'name': {'type': 'string', 'maxLength': 100},
  },
  'additionalProperties': false,
});

app.post('/users', (c) async {
  final body = userSchema.requireMap(await c.body()); // invalid body -> 400
  // ... Dto.fromJson(body), insert, respond ...
}, doc: const RouteDoc(
  success: Success(status: 201, schema: userSchema),
  requestBody: userSchema,
));

final spec = OpenApi.fromRoutes(app.routes, title: 'API', version: '0.1.0');
spec.toJson(); // Map<String, Object?>
spec.toYaml(); // block-style YAML (a scoped emitter, not a general YAML library)
```

## What `fromRoutes` emits

`OpenApi.fromRoutes(List<RouteEntry> routes, {String title = 'API', String version = '0.1.0', List<SecurityScheme> security = const [], override})` emits an `openapi: 3.1.0` document: `info`, `paths` with path/query parameters and per-status responses (every response `description` is the RFC 9110 reason phrase for its status, or `Status <code>` for an unregistered one), `requestBody` under its declared media type, and `components/schemas` plus `components/securitySchemes` collected transitively from every referenced `Schema` and scheme. A route with declared security gains an automatic 401 response unless a user-declared one wins. A route with no `RouteDoc` still emits an operation — a bare 200, the only honest thing there is to say.

The document is a deterministic function of the route set, not of registration order: every generated map is emitted in sorted key order, so two apps with the same routes emit the same bytes. Anything that would silently corrupt that determinism is a hard `StateError` instead: two routes on one method+shape (capture names collapsed, via keta core's own `conflictKey` — the same function `App.compile` uses), two schemas or security schemes sharing a name with different definitions, a duplicate `operationId`, or a duplicate parameter name within one location — each error names the routes involved.

## Every claim here is tested

The project gate is that each documented invariant has a test. The map (`Schema`/`RouteDoc`/`SecurityPolicy`'s own tests moved to `keta`'s suite along with the types — see that package's README):

| Claim | Test |
|---|---|
| paths/parameters/components extraction; determinism across registration order; schema-name, security-scheme, duplicate-route, and duplicate-parameter collisions fail fast; `failureResponses` range 400–599; security default/override/explicitly-public; automatic 401; request-body media types | `test/openapi_generation_test.dart` |
| the declared `Success` reaches the document; a success in `failureResponses` is rejected; the 2xx/3xx range and 204/304 bodyless rules hold as hard errors even with asserts off (release-mode child process); `toYaml` round-trips | `test/openapi_test.dart` (with `test/support/`) |
| an upgrade route emits a 101 (not a 2xx) with the pinned subprotocol header; security's automatic 401 and documented failures compose on it | `test/openapi_upgrade_test.dart` |
| response descriptions are per-status reason phrases (201 "Created", 204 "No Content", …), with an honest `Status <code>` fallback; a `Failure` projects its declared media type and its schema is collected | `test/reason_and_failure_body_test.dart` |
| `description`/`tags`/`operationId` projection; top-level tag aggregation sorted and deduped; a duplicate `operationId` is a hard error naming both routes | `test/route_doc_metadata_test.dart` |
| the YAML emitter: quoting, escaping (C0/DEL as `\xHH`), number-like and reserved strings quoted, empty collections explicit, duplicate stringified keys refused | `test/yaml_test.dart` |
