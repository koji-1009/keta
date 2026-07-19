# keta_openapi

Ring 2 of keta: the `Schema` constant type, `RouteDoc`, and the route-table walk that emits an OpenAPI 3.1 document from runtime values. Everything here is **runtime assembly** — plain `const` Dart values read back at emit time. There is no code generation, no `build_runner`, no annotations, and no reflection anywhere in the package.

## The one-way shadow

Truth flows one way: the running routes and their `RouteDoc`s are the source, and the document is their shadow. `OpenApi.fromRoutes` walks the route table, extracting paths and path parameters mechanically from the route values and bodies/responses from each route's `RouteDoc`; nothing ever flows back — the document never drives the routes, and nothing is inferred from middleware (security, like everything else, travels as declared data). The single escape hatch is `override`, a function that receives the finished document and may rewrite it.

```dart
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

## `Schema` — one constant, three consumers

A `Schema` is a named JSON Schema fragment that is the single source of truth for a type: it drives the emitted OpenAPI, runtime boundary validation, and (via keta_lints) contract tests. The fragment is restricted to keta's canonical subset — primitives, optionals, `List<T>`, `Map<String, T>` (via `additionalProperties`), enums, `$ref` to another schema (listed in `deps` so the walker can collect transitively), and `oneOf` + `discriminator` for sealed types.

`validate(value)` returns a list of violation messages, each carrying a JSON path (`$.items[2].name`); empty means valid. `require(value)` validates and returns the value unchanged, throwing `BadRequest` (400) with the violation list on any problem — validation is the gate, typing the result is the mapper's job. `requireMap(value)` additionally hands the result back typed as `Map<String, Object?>`, the shape every write handler needs before a `Dto.fromJson`, turning a non-object instance into a 400 rather than a cast crash.

### The two-posture rule

Every mistake validation can trip over gets exactly one of two postures, never a third. A malformed **schema** fragment — an `items` that isn't an object, a `$ref` missing from `deps`, a misspelled `type` — is the schema author's defect: a descriptive `StateError` naming the schema and the offending key, which propagates as a 500 and is never blamed on the client. Invalid **instance** data — a missing required property, a wrong type, an out-of-set enum value — is the client's defect: a violation, which `require` turns into a 400.

### The document does not lie

A constraint that appears in the emitted document is also enforced at the runtime boundary. Beyond the shape checks, `validate` enforces `minLength`/`maxLength` (counted in Unicode code points, so `'😀'` is length 1), `pattern` (a Dart `RegExp`, matched unanchored per JSON Schema), `format` for a crisp set only — `date-time`, `date` (RFC 3339), and `uuid`; every other format is an annotation, emitted but never a violation — `minimum`/`maximum` and the 2020-12 numeric `exclusiveMinimum`/`exclusiveMaximum`, `multipleOf` (exact for integers, tolerance-checked for fractional factors), `minItems`/`maxItems`, and `uniqueItems` by deep JSON-value equality. Because `pattern` and `uniqueItems` have hostile-input cost (catastrophic backtracking; an O(n²) scan), each is gated twice: a declared `maxLength`/`maxItems` the value exceeds skips the expensive check (the value is already condemned), and an absolute ceiling — 4096 code points for `pattern`, 8192 items for `uniqueItems` — backstops the schema that omits the bound, so a megabyte-scale body admitted by the request cap never reaches either.

The rule cuts the other way too: **what you can write takes effect; what doesn't take effect can't be written**. A recognized JSON Schema validation keyword keta does not enforce — `const`, `allOf`, `anyOf`, `not`, `if`/`then`/`else`, `prefixItems`, `contains`, `minProperties`, `patternProperties`, and the rest — is authoring damage (`StateError`), because it would be emitted into the document as a promise the boundary silently breaks. Pure annotations (`description`, `example`, `default`, …) pass through untouched.

One deliberate deviation from JSON Schema 2020-12: `type: integer` rejects a zero-fraction double (`1.0`), which the spec admits. The canonical mapper reads `json['x'] as int`, so admitting `1.0` would pass validation only to crash that cast — validation and mapping decide "what is an integer" once, together.

`listSchema(itemSchema)` builds the canonical list-endpoint envelope — `items` (array of `$ref`s to the item schema) and `total` (the un-paginated match count), both required, `additionalProperties: false` — as an ordinary `Schema` carrying the item schema in `deps`. It is a helper over the canonical writing pattern (a judged restraint), not a generic or a generated type.

## `RouteDoc` — the contract, declared not guessed

A `RouteDoc` rides on a route as its opaque `doc:` and is read back at emit time. Its `success` is **required**: a contract with no success is unrepresentable, so the emitter never fabricates a 200 for a documented route — `POST /users` answers 201 and `DELETE /users/:id` answers 204, and each is declared. `Success` carries `status` (2xx/3xx, default 200), an optional body `schema` (null for a bodyless answer; a schema on a 204/304 is rejected — constructor `assert` in debug, hard emit-time error in release), and a `contentType` (default `application/json`). A WebSocket route uses `RouteDoc.upgrade` with a `SwitchingProtocols` instead — a 101 is neither a 2xx nor a 3xx, so it is a different type, not a permissive `Success` — and the shadow documents the switch itself, including the pinned subprotocol as a `Sec-WebSocket-Protocol` response header.

`failureResponses` maps a 400–599 status to either a bare `Schema` (an `application/json` body, the common case) or a `Failure(schema, contentType: ...)` for a non-JSON error body; a key outside 400–599 is a hard error naming the route. `security` is an OR-list of `SecurityScheme`s (constants `bearer` and `apiKey` are provided): `null` follows the global default passed to `fromRoutes`, an empty list declares the route explicitly public. `query` declares query parameters by reusing `Capture` for its schema fragment; required-ness at runtime is the handler's accessor choice (`c.query` vs `c.tryQuery`), not this flag. `summary`, `description`, `tags` (aggregated sorted and deduped into the document's top-level `tags`), and `operationId` (document-wide unique, enforced at emit) round out the metadata.

## What `fromRoutes` emits

`OpenApi.fromRoutes(List<RouteEntry> routes, {String title = 'API', String version = '0.1.0', List<SecurityScheme> security = const [], override})` emits an `openapi: 3.1.0` document: `info`, `paths` with path/query parameters and per-status responses (every response `description` is the RFC 9110 reason phrase for its status, or `Status <code>` for an unregistered one), `requestBody` under its declared media type, and `components/schemas` plus `components/securitySchemes` collected transitively from every referenced `Schema` and scheme. A route with declared security gains an automatic 401 response unless a user-declared one wins. A route with no `RouteDoc` still emits an operation — a bare 200, the only honest thing there is to say.

The document is a deterministic function of the route set, not of registration order: every generated map is emitted in sorted key order, so two apps with the same routes emit the same bytes. Anything that would silently corrupt that determinism is a hard `StateError` instead: two routes on one method+shape (capture names collapsed, mirroring keta core's own conflict rule), two schemas or security schemes sharing a name with different definitions, a duplicate `operationId`, or a duplicate parameter name within one location — each error names the routes involved.

## The runtime counterpart

`enforceSecurity(SecurityPolicy(defaults: [...], verifiers: {...}))` is the middleware that makes the declarations bite: it reads the matched route's `RouteDoc.security` off `c.routeDoc`, OR-combines the declared schemes' verifiers (any one admitting passes; an explicitly public route skips the check), and throws `Unauthorized` when none admit. Credential verification itself is app code — keta owns only the plumbing that matches declarations to verifiers, so "keta ships no auth" stands.

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| the two-posture rule: authoring damage is a `StateError`, instance data a violation; `require` throws `BadRequest` (400); `requireMap` types the object or 400s | `test/schema_validation_test.dart` |
| the canonical subset end to end: `$ref` through `deps`, `oneOf` + `discriminator` (implicit and explicit mapping), enums on any type, `additionalProperties`, deep violation paths; `1.0` is not an `integer` (deliberate deviation) | `test/schema_validation_test.dart` |
| every enforced value keyword: code-point lengths, unanchored `pattern` with its maxLength gate and 4096 ceiling, the crisp `format` set, exclusive bounds, `multipleOf` tolerance, deep-equality `uniqueItems` with its maxItems gate and 8192 ceiling | `test/schema_value_keywords_test.dart` |
| a recognized-but-unenforced validation keyword (`const`, `allOf`, …) is authoring damage, even beside a `$ref` | `test/schema_value_keywords_test.dart` |
| paths/parameters/components extraction; determinism across registration order; schema-name, security-scheme, duplicate-route, and duplicate-parameter collisions fail fast; `failureResponses` range 400–599; security default/override/explicitly-public; automatic 401; request-body media types | `test/openapi_generation_test.dart` |
| the declared `Success` reaches the document; a success in `failureResponses` is rejected; the 2xx/3xx range and 204/304 bodyless rules hold as hard errors even with asserts off (release-mode child process); `toYaml` round-trips | `test/openapi_test.dart` (with `test/support/`) |
| an upgrade route emits a 101 (not a 2xx) with the pinned subprotocol header; security's automatic 401 and documented failures compose on it | `test/openapi_upgrade_test.dart` |
| response descriptions are per-status reason phrases (201 "Created", 204 "No Content", …), with an honest `Status <code>` fallback; a `Failure` projects its declared media type and its schema is collected | `test/reason_and_failure_body_test.dart` |
| `description`/`tags`/`operationId` projection; top-level tag aggregation sorted and deduped; a duplicate `operationId` is a hard error naming both routes | `test/route_doc_metadata_test.dart` |
| the route-conflict key agrees with keta core's private `conflictKey` over a corpus (the hand-copy cannot drift silently) | `test/conflict_key_parity_test.dart` |
| `listSchema`'s envelope shape (`items` + `total` required, closed), its `deps` wiring, and its validation behavior including nested `$ref` paths | `test/list_schema_test.dart` |
| `enforceSecurity`: OR-combination, `defaults` fallback, explicitly-public skip, a scheme with no registered verifier is skipped not passed | `test/security_test.dart` |
| the YAML emitter: quoting, escaping (C0/DEL as `\xHH`), number-like and reserved strings quoted, empty collections explicit, duplicate stringified keys refused | `test/yaml_test.dart` |
