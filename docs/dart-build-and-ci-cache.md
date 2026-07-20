# Dart build artifacts and what CI should cache

The survey behind keta's CI cache design. Every number here was measured — on GitHub Actions (runs 29728112735 and 29728112698) or locally on macOS arm64 — and nothing is estimated.

## 1. What a Dart build produces

A Dart build writes five independent kinds of artifact. Each has its own location, its own invalidation trigger, and its own regeneration cost, and those boundaries are what a cache entry should follow.

### 1.1 Package resolution — `~/.pub-cache` and `.dart_tool/package_config.json`

`dart pub get` downloads dependencies into `PUB_CACHE` (`~/.pub-cache` by default) and writes `package_config.json`, `package_graph.json`, and `native_assets.yaml` at the workspace root. The former is shared machine-wide; the latter are rewritten on every resolve.

- Invalidated by: a change to `pubspec.lock`.
- Cost: **0.2 s** with a warm `~/.pub-cache` (7 s across all 19 jobs), with no downloads.

### 1.2 Build hooks — `.dart_tool/hooks_runner/`

Packages carrying native assets (keta_native, sqlite3) ship a `hook/build.dart` that the hooks runner executes. Its output splits across two trees:

| Path | Contents |
|---|---|
| `hooks_runner/<pkg>/<config>/` | `hook.dill` (the compiled hook, ~12 MB), `input.json`, `output.json`, two dependency-hash files |
| `hooks_runner/shared/<pkg>/build/<config>/` | What the hook produced — for keta_native, `libcrypto` as a dynamic library or a static archive |
| `hooks_runner/shared/<pkg>/link/<hash>/` | Link-hook output (AOT only) |

`<config>` hashes the **build configuration**, not the consuming package. Comparing `input.json` between two of them, the only difference is `linking_enabled`, with an identical `package_root`; on CI all four consumer jobs compiled into the same `shared/keta_native/build/6b4ebf10e7`. Artifacts are therefore shareable between jobs that agree on the configuration.

Two hash files decide whether the hook re-runs:

- `hook.dependencies_hash_file.json` — `hook/build.dart`, `package_config.json`, and the SDK's `version` file: whether to rebuild the hook itself.
- `dependencies.dependencies_hash_file.json` — whatever the hook registered in `output.dependencies`. For keta_native that is **470 files inside the BoringSSL checkout** plus `boringssl_commit.txt`, 471 in all. No `~/.pub-cache` path appears.

**A missing dependency re-runs the hook.** Deleting only the checkout while keeping the compiled artifacts, then rebuilding, refetched the tarball and recompiled all 368 translation units (375 `Fetching`/clang lines); restoring the checkout made the same build a no-op (0 lines). The artifact cache is therefore useless without the source cache.

- Cost: the full BoringSSL compile takes **175–192 s** on CI (dynamic, test jobs) or **2 m 43 s** (static plus link, AOT job). Fetching and extracting the tarball takes **10–35 s**.

### 1.3 Test runner — `.dart_tool/test/incremental_kernel.*`

`dart test` keeps an incrementally compiled kernel, ~4 MB at the workspace root and again under each package.

- Cost: on keta, the largest package, cold **1.72 s** against warm **1.48 s** — a difference of 0.24 s.

### 1.4 Executable snapshots — `.dart_tool/pub/bin/`

`dart run <pkg>:<bin>` snapshots the executable on first use: locally 44 MB for keta_lints, 25 MB for test, 1.1 MB for keta_files. The test matrix never creates these — only the checks job's `dart run keta_files:check` does.

### 1.5 AOT bundle — `build/cli/<target>/bundle/`

`dart build cli` runs the build hooks, then the link hooks, then assembles the executable and its native libraries. When the artifacts from 1.2 are valid the hooks are skipped and only the assembly runs.

## 2. Where CI time actually goes

Step timings for the 19-job test matrix (run 29728112735), totalling 2058 runner-seconds:

| Step | Total | Median | Max |
|---|--:|--:|--:|
| `dart test` | 1059s | 17s | 192s |
| setup-dart | 509s | 23s | 72s |
| apt-get install | 300s | 11s | 47s |
| caches (restore + save, 86 steps) | 77s | 0s | 13s |
| checkout | 63s | 1s | 13s |
| `dart pub get` | 7s | 0s | 2s |

The two runner tiers behave differently:

- ubuntu-latest (the four BoringSSL jobs, lints, rds): setup-dart 8 s, apt 6–7 s. Time concentrates in `dart test`, which is the BoringSSL compile (117–192 s).
- ubuntu-slim (the other 13): setup-dart 33–53 s and apt 16–47 s against a `dart test` of 29–41 s. **Preparation outlasts the tests.**

Wall-clock is set by the slowest job, `packages/keta_oidc` at 215 s, of which 192 s is the BoringSSL compile.

## 3. What CI should shorten

The measurements leave three targets.

**D1. The BoringSSL compile (175–192 s across four jobs, and the wall-clock driver) — cache it.**
It is the only artifact measured in minutes, and it is what the cache exists for. Section 1.2 makes both halves mandatory: the artifacts *and* the source they depend on. They are separate entries because their invalidation differs — the source turns over only with the pin (`boringssl_commit.txt`), the artifacts with any hook change — so editing hook code while leaving the pin alone still hits the source cache and saves the 10–35 s fetch. The AOT job's differing `linking_enabled` needs its own entry: a saved cache is immutable, so one key cannot hold two configurations.

**D2. Package downloads — keep caching them.**
The `~/.pub-cache` entry is what keeps `dart pub get` at 0.2 s. Dropping it puts a network wait on all 19 jobs.

**D3. apt-get (300 s) — not a caching problem; scope it instead.**
`libsqlite3-dev` was installed on all 19 jobs, while `package:sqlite3` is reached by three: keta_sqlite and the two examples that use it. The other 16 installs are waste.

**D4. setup-dart (509 s) — leave it alone.**
The SDK download happens inside the action, which exposes no cache input (its README documents none). Slim being slower is the runner tier. Caching a several-hundred-megabyte SDK ourselves is not obviously faster than downloading it, and is not worth doing on a guess.

**Deliberately not cached:**

- `.dart_tool/test` (incremental kernel): worth 0.24 s — not worth an entry.
- `.dart_tool/pub/bin` (70 MB of snapshots): the matrix jobs never create them; the checks job that does finishes in 12 s.
- `.dart_tool` as a whole: it adds the two above plus `package_config.json`, which is rewritten every run, and otherwise duplicates the hooks-runner entry — while diverging per job, which makes a shared key harder.

## 4. Implementation

- D1: `boringssl-src` (keyed on the pin, shared by every job), `boringssl-obj` (keyed on hook code, shared by the test jobs), `boringssl-aot` (keyed on hook code, AOT job).
- D2: `pub-<os>-<pubspec.lock>`.
- D3: install `libsqlite3-dev` only in the jobs that reach sqlite3.
- D4: unchanged.
