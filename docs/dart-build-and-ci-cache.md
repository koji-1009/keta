# Dart のビルド成果物と CI キャッシュ設計

keta の CI で「何を短縮すべきか」を決めるための一次調査。測定はすべて実機(GitHub Actions の run 29728112735 / 29728112698、および macOS arm64 のローカル)で取得したもので、推定値は含まない。

## 1. Dart パッケージのビルドが生む成果物

Dart のビルドは独立した 5 層の成果物を生む。層ごとに置き場所・再生成のトリガ・コストが違い、キャッシュの単位もそこで決まる。

### 1.1 パッケージ解決 — `~/.pub-cache` と `.dart_tool/package_config.json`

`dart pub get` は依存を `PUB_CACHE`(既定 `~/.pub-cache`)へダウンロードし、ワークスペース直下に `package_config.json` / `package_graph.json` / `native_assets.yaml` を書く。前者はマシン単位で共有され、後者はワークスペース単位で毎回書き直される。

- 無効化: `pubspec.lock` の変更(= 解決結果の変更)。
- コスト: `~/.pub-cache` が温まっていれば **0.2 秒**(19 ジョブ合計 7 秒)。ダウンロードは発生しない。

### 1.2 ビルドフック — `.dart_tool/hooks_runner/`

ネイティブアセットを持つパッケージ(keta_native、sqlite3)は `hook/build.dart` を持ち、hooks runner がこれを実行する。ディレクトリは 2 系統に分かれる。

| パス | 内容 |
|---|---|
| `hooks_runner/<pkg>/<config>/` | `hook.dill`(フックのコンパイル済みカーネル、約 12 MB)、`input.json`、`output.json`、依存ハッシュ 2 種 |
| `hooks_runner/shared/<pkg>/build/<config>/` | フックが生成した成果物(keta_native なら `libcrypto` の動的ライブラリまたは静的アーカイブ) |
| `hooks_runner/shared/<pkg>/link/<hash>/` | リンクフックの出力(AOT のみ) |

`<config>` は**ビルド設定のハッシュ**で、消費パッケージ名は入らない。`input.json` を比較すると差は `linking_enabled` のみで `package_root` は同一であり、CI でも 4 つの消費ジョブ全てが同じ `shared/keta_native/build/6b4ebf10e7` を使った。したがって設定が同じジョブ間で成果物は共有できる。

再実行の判定は 2 つのハッシュファイルによる。

- `hook.dependencies_hash_file.json` — `hook/build.dart`、`package_config.json`、SDK の `version` ファイル。フック自体を作り直すかを決める。
- `dependencies.dependencies_hash_file.json` — フックが `output.dependencies` に登録した入力。keta_native では **471 件中 470 件が BoringSSL チェックアウト内のファイル**、残り 1 件が `boringssl_commit.txt`。`~/.pub-cache` のパスは 1 件も含まれない。

**依存ファイルが欠けるとフックは再実行される。** 成果物を残したままチェックアウトだけ削除して AOT ビルドすると、再取得と 368 TU の再コンパイルが走った(`Fetching` + clang 起動が 375 行)。チェックアウトを戻すと同じビルドが 0 行、すなわち完全スキップになる。つまり **成果物キャッシュはソースキャッシュ無しでは機能しない**。

- コスト: BoringSSL の全コンパイルが CI で **175〜192 秒**(動的、テストジョブ)/ **2 分 43 秒**(静的 + リンク、AOT ジョブ)。tarball の取得と展開が **10〜35 秒**。

### 1.3 テストランナー — `.dart_tool/test/incremental_kernel.*`

`dart test` はテスト用カーネルを差分コンパイルして保持する。ワークスペース直下と各パッケージ配下に約 4 MB ずつ。

- コスト: keta(最大のパッケージ)で cold **1.72 秒** → warm **1.48 秒**。差は 0.24 秒。

### 1.4 実行可能ファイルのスナップショット — `.dart_tool/pub/bin/`

`dart run <pkg>:<bin>` は初回にスナップショットを作る。ローカルでは keta_lints 44 MB、test 25 MB、keta_files 1.1 MB の計 70 MB。テストマトリクスのジョブはこれを作らない(`dart test` は自前の経路を使う)。checks ジョブの `dart run keta_files:check` だけが該当する。

### 1.5 AOT バンドル — `build/cli/<target>/bundle/`

`dart build cli` はビルドフックに加えリンクフックを走らせ、実行ファイルとネイティブライブラリを配置する。上流の成果物(1.2)が有効ならフックはスキップされ、バンドルの組み立てだけが走る。

## 2. CI の時間はどこに消えているか

run 29728112735(テストマトリクス 19 ジョブ)のステップ実測。合計 2058 ランナー秒。

| ステップ | 合計 | 中央値 | 最大 |
|---|--:|--:|--:|
| `dart test` | 1059s | 17s | 192s |
| setup-dart | 509s | 23s | 72s |
| apt-get install | 300s | 11s | 47s |
| キャッシュ(復元 + 保存、86 ステップ) | 77s | 0s | 13s |
| checkout | 63s | 1s | 13s |
| `dart pub get` | 7s | 0s | 2s |

ランナー種別で性格が変わる。

- ubuntu-latest(BoringSSL 系 4 + lints + rds): setup-dart 8 秒、apt 6〜7 秒。時間は `dart test` に集中し、その中身は BoringSSL のコンパイル(117〜192 秒)。
- ubuntu-slim(残り 13): setup-dart 33〜53 秒、apt 16〜47 秒に対し `dart test` は 29〜41 秒。**準備がテスト本体より長い。**

体感時間(= 最長ジョブ)は keta_oidc の 215 秒で、その 192 秒が BoringSSL のコンパイル。

## 3. 何を短縮すべきか

上の測定から、対象は 3 つに絞られる。

**D1. BoringSSL のコンパイル(175〜192 秒 × 4 ジョブ、体感時間の支配要因)— キャッシュする。**
分単位の成果物はこれだけで、キャッシュの主目的はここに尽きる。1.2 の依存関係から、成果物とソースの**両方**が必要。エントリを 2 本に分けるのは無効化条件が違うため: ソースは pin(`boringssl_commit.txt`)だけで変わり、成果物はフックコード全体で変わる。フックを編集して pin を据え置いた場合、ソース側はヒットのまま再取得 10〜35 秒を節約する。設定違い(`linking_enabled`)の AOT ジョブは別エントリになる — 保存済みキャッシュは不変なので、1 キーに 2 設定は同居できない。

**D2. パッケージのダウンロード — キャッシュする(現状維持)。**
`~/.pub-cache` のキャッシュが効いて `dart pub get` は 0.2 秒。外すとネットワーク待ちが 19 ジョブ分乗る。

**D3. apt-get(300 秒)— キャッシュではなく、不要なジョブから外す。**
`libsqlite3-dev` を全 19 ジョブで入れているが、`sqlite3` に依存するのは keta_sqlite と、それを使う examples/register・examples/files の 3 つだけ。残り 16 ジョブの apt は無駄。

**D4. setup-dart(509 秒)— 手を出さない。**
SDK の取得はアクションの内部処理で、キャッシュ入力を持たない(README に該当記述なし)。slim で遅いのはランナーの性能差。自前で SDK をキャッシュする案はあるが、SDK 実体は数百 MB でキャッシュ復元がダウンロードより速い保証がなく、根拠なしに触らない。

**キャッシュしないと決めたもの。**

- `.dart_tool/test`(差分カーネル): 効果 0.24 秒。エントリを増やす価値がない。
- `.dart_tool/pub/bin`(スナップショット 70 MB): テストマトリクスのジョブが作らない。checks ジョブのみが使い、そこは現状 12 秒で完走している。
- `.dart_tool` 全体: 上の 2 つと `package_config.json`(毎回再生成)を巻き込むだけで、実質は hooks_runner のキャッシュと同じ。ジョブごとに中身が割れる分、キーの共有が難しくなる。

## 4. 実装

- D1: `boringssl-src`(pin キー、全ジョブ共有)、`boringssl-obj`(フックキー、テストジョブ共有)、`boringssl-aot`(フックキー、AOT ジョブ)。実装済み。
- D2: `pub-<os>-<pubspec.lock>`。実装済み。
- D3: apt を sqlite 利用ジョブに限定する。本調査で追加。
- D4: 変更なし。
