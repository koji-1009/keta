# keta_lints

The contract-first toolchain for keta: diagnostics with stable IDs, the materializing `check`/`fix` loop, and the `scaffold` code generator. It ships as two surfaces over one engine — a set of `dart run keta_lints:*` CLIs whose exit codes gate CI, and an analyzer plugin that puts the same findings in the IDE — so a squiggle in the editor and a red CI line are always the *same* finding, with the same ID and the same message.

The problem it exists for: keta has no codegen and no reflection, so the canonical DTO form (`fromJson`/`toJson`/`Schema`) is ordinary hand-owned Dart. Anything hand-owned can drift — a field added without its mapper key, a Schema constant that stops matching the class, a served route the contract never documented. keta_lints makes each of those a loud, correlatable failure instead of a runtime surprise.

## Stable IDs

Every diagnostic prints as `[<id>] <rule>: <message> (<file>)`, where `<id>` is the first 16 hex characters of `sha256(file|scope|rule)`. The file component is normalized to a package-relative path, so the same finding carries the same ID across runs, machines, and the CLI/plugin boundary — an agent (or a suppression list) can correlate it even as line numbers move. Distinct drift axes on one scope carry distinct rule IDs precisely so their stable IDs never collide.

## The check/fix loop

```bash
dart run keta_lints:check canonical lib/   # report drift; exits 1 on any finding
dart run keta_lints:fix canonical lib/     # materialize / reconcile, in place
dart run keta_lints:check canonical lib/   # converged: exits 0
```

`check` covers seven subcommands, each over files or directories (except `drift`, which takes two documents):

```
dart run keta_lints:check drift <oracle.yaml> <shadow.yaml>
dart run keta_lints:check canonical <file-or-dir> ...
dart run keta_lints:check routes <file-or-dir> ...
dart run keta_lints:check query <file-or-dir> ...
dart run keta_lints:check internal-await <file-or-dir> ...
dart run keta_lints:check key <file-or-dir> ...
dart run keta_lints:check tx <file-or-dir> ...
```

`fix canonical` is the materializing half: for every DTO-shaped class it regenerates the drifted canonical members — `fromJson`, `toJson`, and the matching `Schema` constant — **whole**, from the field set, and rewrites the file in place. The generated code is ordinary Dart in the user's own file; ownership transfers on write, and a second run is a no-op. Whole-member regeneration makes the edits non-overlapping by construction, and only the member that actually drifted is touched: a schema-only drift never rewrites a mapper, a non-drifted member stays byte-for-byte identical (inline comments included), and a leading `///` doc comment on a regenerated member is preserved.

Check and fix consult the *same* recognizer, so they never disagree. A class is a DTO by signal — it has a `Schema` constant, a `fromJson`, or a `toJson` — never by the shape of its fields, so plain service classes are never flagged. Abstract, sealed, and `extends`-bearing classes are ignored by both. When the fixer must decline — a positional constructor, a hand-modified mapper, a field type outside the canonical subset (`String`/`int`/`double`/`bool`, same-file enums and DTOs, and non-nested `List<T>`/`Map<String, T>` of those) — the check message names the exact blocker and says to do it by hand, rather than recommending a command that would silently no-op. A hand-modified mapper (a spread, a back-compat alias key, a computed value) is left untouched *and* unverified: its key set can't be trusted, so the tool honors the hand edit with silence. Schema reconciliation is judged independently, so a positional ctor blocks the mapper repair but not the Schema repair.

## The diagnostics

| Rule | Fires when | `check` subcommand |
|---|---|---|
| `keta_canonical_missing` | a DTO lacks a `fromJson` factory or a `toJson` method | `canonical` |
| `keta_canonical_drift` | mapper keys disagree with the final fields, in either direction | `canonical` |
| `keta_schema_drift` | the `Schema` constant's `properties` disagree with the fields | `canonical` |
| `keta_type_drift` | a `fromJson` cast (or an enum wire accessor) disagrees with the field's declared type | `canonical` |
| `keta_param_unknown` | `c.param('x')` where `x` is not a capture in the route template | `routes` |
| `keta_capture_unused` | a path capture the handler never reads via `c.param` | `routes` |
| `keta_query_undeclared` | `c.query`/`tryQuery`/`queryAll` on a name not declared in `RouteDoc(query: [...])` | `query` |
| `keta_query_drift` | a query param declared `required: true` but read with `tryQuery` | `query` |
| `keta_key_inline` | a `Key(...)` constructed inline at a `get`/`tryGet`/`set` call — identity keys make the value unreachable | `key` |
| `keta_tx_outside_recover` | `use(tx())` registered before `use(recover())`, so the transaction commits a failed request | `tx` |
| `keta_internal_await` | `await` in framework composition code (framework-development only); opt out per line with `// keta:allow-await` | `internal-await` |
| `keta_contract_drift` | an endpoint, schema, or field present on only one side of the contract diff | `drift` |
| `keta_contract_type_drift` | a field present on both sides whose type differs | `drift` |
| `keta_contract_required_drift` | a field required on one side but optional on the other | `drift` |

## Contract drift

`check drift` diffs the externally-supplied contract (the oracle) against the OpenAPI document the code emits (the shadow) — a pure document diff, needing no running route table. Every divergence is directional: an oracle-only endpoint says "materialize the route skeleton", a shadow-only one says "document it or remove the route", and type/required drift on a shared field each carry their own rule ID. The oracle is external input, so a malformed document becomes descriptive drift, never a bare `TypeError` crashing the CI gate; reordering an enum's members is not drift (the comparison is set-wise).

## Scaffold

```bash
dart run keta_lints:scaffold openapi.yaml [outDir]
```

`scaffold` materializes user-owned Dart from an OpenAPI 3.1 contract: `lib/dtos.dart` (DTOs with mappers and Schema constants, enhanced enums with wire mappings, sealed oneOf variants), `lib/routes.dart` (typed route skeletons that throw 501), `tool/openapi.dart`, and `test/dto_contract_test.dart`. Existing files are never overwritten — once written, the files are yours, and the check/fix loop is what keeps them honest from then on. A construct outside the canonical subset raises a descriptive `ScaffoldError` (exit 65) rather than guessing.

## The analyzer plugin

Enable it from a consuming package's `analysis_options.yaml`:

```yaml
plugins:
  keta_lints: ^0.1.0
```

The five route/query/canonical/tx/key rules are warnings, on by default once the plugin is enabled, and surface the same IDs and messages as the CLI; standard `// ignore:` comments suppress them. `keta_internal_await` is an opt-in lint (`diagnostics: keta_internal_await: true`), meaningful only over keta's own source. Cross-file checks — contract drift among them — remain CLI-authoritative and are not part of the plugin.

## Deliberately not attempted

Documented non-goals, not gaps: the `key` rule does not chase a `Key` built inline and bound to a local before use — that would need data-flow analysis this syntactic rule deliberately avoids. The `query` rule skips a `doc:` that is not an inspectable inline `RouteDoc` rather than risk a false positive. All source rules are single-file and syntactic — no resolution — which is what lets the CLI run over bare files and the plugin reuse the analyzer's parse.

## Every claim here is tested

The project gate is that each documented invariant has a test. The map:

| Claim | Test |
|---|---|
| the CLI contract: `check` exits 0/1/64, walks directories; `fix` rewrites in place and is a no-op on re-run; `scaffold` writes the four files, skips existing ones, exits 64/65/66 | `test/cli_test.dart` |
| stable IDs: 16 hex chars, stable across runs, keyed on the package-relative path | `test/keta_lints_test.dart` |
| canonical missing/drift/schema/type findings; refusal messages name the real blocker; abstract/sealed/subclass and hand-modified mappers are left silent; schema drift is independent of the mappers | `test/canonical_check_test.dart` |
| fix materializes and reconciles whole members without corrupting source, touches only the drifted member (comments elsewhere survive), and refuses what it must not touch | `test/canonical_fix_test.dart` |
| contract drift in every direction; distinct axes on one field get distinct IDs; enum member order is not drift; a malformed oracle is descriptive drift, not a crash | `test/drift_test.dart` |
| the route, query, key, tx-order, and internal-await rules, including `keta:allow-await` suppression and the distinct-ID regressions | `test/keta_lints_test.dart` |
| the plugin rules fire with the exact IDs and messages the CLI produces, and `// ignore:` comments suppress them | `test/plugin/rules_test.dart` |
| scaffold output shapes — canonical DTOs, 501 route skeletons, contract tests, enhanced enums — plus `ScaffoldError` on every out-of-canonical or malformed input, and a scaffold → check → fix round-trip that converges clean | `test/scaffold_test.dart` |

The register example carries the loop end-to-end as a living demo: `examples/register/test/canonical_drift_demo_test.dart` injects a field, watches `check` fail, runs the fix, and watches `check` converge.
