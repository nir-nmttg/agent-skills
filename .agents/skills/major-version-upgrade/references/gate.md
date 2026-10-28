# 静的確認を更新の反映に結びつける

`scripts/supply-chain.py` は Python 3.9 以降の標準ライブラリで動く。供給網・互換性を静的に確認した候補を固定し、対象コードを実行せず反映用 snapshot を保存する。検証方式の選択は不要で、ゲートから executor・依存管理コマンドを起動する機能はない。任意の実行検証は [隔離手順](isolation.md#追加検証) の別 RUN で扱う。

## 1. 候補と実行記録を準備する

1. スキル実体の `scripts/new-run.sh <project-slug>` を `bash` で実行し、出力先を `RUN` とする。対象プロジェクト・候補コピー・RUN は分離する。
2. 候補編集前に [保存・反映契約](isolation.md#6-検証した差分を保存して対象へ反映する) の許可範囲・初期状態を親側へ記録する。候補は秘密・依存・cache・`.git` を除く最小コピーとし、正しい manifest・lockfile・環境指定・必要な移行ソースを初期化前に完成させる。
3. 全直接・間接・dev・build・optional・platform 等の依存を inventory にまとめ、変更した全候補の取得元・正確な版・取得物 hash・公開日時を固定する。コード評価を伴う解決・生成は初期化前から [隔離](isolation.md) を適用する。正しい候補を作れない対象は保留する。
4. 候補版と新たに採用する全実配布物（wheel・image 等）の最新の公式公開日時から **7日以上** を必須とする。最新安定版が7日未満なら7日以上経過した適切な安定版を選び、適切な版がなければ当該対象を保留して再開可能日を報告する。日時不明・未来も保留し、不明な再開日は推測しない。緊急修正を含め下限を短縮する override はない。

`UPGRADE_PYTHON` はプロジェクト外の信頼済み Python 3.9 以降の実体、`UPGRADE_GATE` はこのスキル実体の `scripts/supply-chain.py` の絶対パスとする。対象の venv・shim・PYTHONPATH・site 由来のコードを起動へ持ち込まず、常に `-I -S` を付ける。

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" init --run "$RUN" --project "$PROJECT" --candidate "$CANDIDATE" --plan "$RUN/plan.json"
```

## 2. 固定の6項目を証拠付きでレビューする

初期状態はすべて `unknown`。実際の非空の根拠と説明を `RUN` 内へ保存し、一項目ずつ `review` する。URL だけ、空ファイル、未確認の文章を証拠にしない。機械検査や archive の signal だけで `pass` にしない。

| check | 必要な確認 |
| --- | --- |
| `coverage` | 全依存 inventory と差分が manifest・lockfile・対象環境・dev/build/optional 等の範囲を覆い、変更版・取得物に抜けがない |
| `sources` | 名前・公開元・所有者・repository・配布 URL の連続性と、取得元変更の公式根拠 |
| `artifacts` | 新旧配布物の実際の差分、hook・生成コード・通信・秘密へのアクセス、archive signal の意味 |
| `advisories` | 更新後の全ライブラリ・ビルド依存とランタイムを対象にした、既知の脆弱性・悪性告知の確認、DB/情報の鮮度・範囲・限界 |
| `authenticity` | 公認 digest と署名/provenance の公開主体。未提供なら独立した代替根拠と限界 |
| `compatibility` | 公式の版条件・移行手順・利用箇所・ABI/peer/build 依存・言語間連携と、manifest/lockfile/移行ソースの静的整合 |

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" review --run "$RUN" --check coverage --status pass --evidence evidence/coverage.md --note "全依存と変更範囲を照合した根拠"
```

残る5項目もそれぞれ実際の証拠で記録する。`isolation` の承認項目はなく、隔離環境の成功を静的レビューの代用にしない。静的根拠不足・明確な非互換・未解消の既知問題・実際に判明した更新由来の失敗があれば、該当項目を通さず修正または対象を保留する。

監査 JSON を用意できれば `audits` へ含める。提示した npm audit v2・pip-audit・bundler-audit JSON の finding・error・skip・未対応形式・期限切れ・同 component 内の対象版 coverage 不足は停止する。既に得た不都合な結果を除外・加工して通さない。JSON 未収集の component は `automated-checks.json` の `manual_advisory_components`、全更新後依存は `inventory_after` に出る。その全 ID・名前・版を公式告知・advisory DB と照合し、取得日時・URL・対象版・結果を `coverage` / `advisories` の根拠へ対応づける。変更していない依存も省かず、未確認の範囲が残れば保留する。

## 3. 検査した候補を一度だけ固定する

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" check --run "$RUN"
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" run --run "$RUN"
```

6項目の有効な `pass` と機械検査が揃うまで停止する。証拠・監査の有効期間は24時間。公開7日待機は `check` と snapshot 作成後の直前検査の双方で適用する。取得物・inventory・計画・候補ソース・根拠・検査コードの hash を固定し、承認後やコピー中の差替えを拒否する。既存の証拠変更・期限切れ・`pass` の差替えや `fail` からの復活、失敗/実行済みの RUN の再利用はせず、新しい記録で確認し直す。

`run` はコードや子プロセスを起動せず、`execution-inputs/candidate` と `execution-output/static-result.json` を保存する。結果は `static_ready` / `runtime_verified: false` で、導入・テスト成功を意味しない。`source_manifest` は元候補の hash と mode、`not_performed` はこの静的 run 自体が実行していない工程を記録する。任意の追加検証の結果は別途報告する。

[保存・反映契約](isolation.md#6-検証した差分を保存して対象へ反映する) に従い、snapshot の hash を照合し、対象の全適用予定パスの初期状態と競合がないことを確認して、許可した差分・実行 bit・削除だけを反映する。snapshot の `0400` / `0500` や保存出力の `0600` を反映先の mode にしない。反映後にソースだけを修正する場合も [再確認手順](isolation.md#反映後に修正が必要になった場合) に従い、当該更新分を安全に取り下げて実際の更新前グラフから修正済み候補を確認し直す。

## 計画JSONとinventoryの形式

計画・状態は `schema_version: 2` を使う。新規計画の検証モード指定は不要。互換用の `verification_mode: "static"` だけは受け付けるが、別の検証方式や `execution` を含む計画は拒否する。過去の実行付き計画・状態・承認を流用せず、新しい静的計画を作る。JSON の重複キー・未対応キー・不正な型、symlink・hardlink・特殊ファイル・`..` 参照は拒否する。

以下は構造例で、版・日時・hash・パスを実際に確認した値へ置き換える。

```json
{
  "schema_version": 2,
  "unit": "web-widget-update",
  "files": ["package.json", "package-lock.json"],
  "inventory": "inventory.json",
  "candidates": [
    {
      "id": "node:widget",
      "published_at": "2026-01-01T00:00:00Z",
      "stability": "stable",
      "compatibility": "compatible",
      "artifacts": [
        {"path": "packages/widget-1.1.0.tgz", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      ]
    }
  ],
  "audits": []
}
```

- `unit` は更新単位の説明。major は一件と不可分な関連セットを記録し、関連性は `coverage` / `compatibility` で確認する。
- `files` は対象・候補の双方で監視する相対パス。manifest・lockfile・取得元設定・CI 等を列挙する。候補コピー全体も別に hash/mode を固定するが、元プロジェクト全体を自動固定したことにはしない。
- `published_at` は候補版と全新規配布物（`runtime_image` を含む）の公式公開日時のうち最新の値を UTC の `Z` 表記で指定する。新しい wheel/image を古い版の初回公開日で代用しない。作成日時を公開日と推定せず、一つでも不明なら保留する。
- `stability` は `stable/prerelease/unknown`、`compatibility` は `compatible/migration/unknown`。安定版を選び、互換性が不明な候補を承認しない。minor は `compatible` のみ扱う。
- `artifacts` は採用する全ファイル配布物の RUN 内相対パスと公認 SHA256。通常のライブラリ・archive で供給するランタイムは非空。`runtime_image` で供給するランタイムだけは空を許可する。旧配布物との差分と出所は別途レビューする。
- `runtime_image` は `kind: runtime` 専用の省略可能な object。`reference` は tag のない `repository@sha256:<64桁>` で、更新後 inventory の `source` と同じ参照にする。`image_id` は任意で、指定するなら `sha256:<64桁>`。Docker の実行設定や実測版は要求せず、`runtime_images.version` は inventory の申告値であると区別する。image 自体の公開日・出所・署名等も確認する。
- `audits` は実際の無加工 JSON の RUN 内パスと `ecosystem/component/format/exit_code/checked_at`。形式は `node:npm-v2`、`python:pip-audit`、`ruby:bundler-audit`。`checked_at`・終了コードは実測値とし、ツール版・送信先・範囲・DB 鮮度も根拠に残す。Python は全 after package の正規化名・版を照合する。npm/bundler の範囲は `coverage` でも確認する。JSON 未提供分の手動照会も全依存を覆う必要がある。
- plan・inventory・取得物・監査 JSON・証拠は RUN 内の通常ファイルとし、秘密値・実データを含めない。取得元 URL の認証情報は保存しない。

inventory は全依存の更新前後の解決結果を記録する。次も構造例で、実際の manifest・lockfile・採用方式と照合する。

```json
{
  "before": [
    {"id": "node:widget", "component": "web", "ecosystem": "node", "kind": "direct", "name": "widget", "version": "1.0.0", "source": "https://registry.example.invalid/widget"}
  ],
  "after": [
    {"id": "node:widget", "component": "web", "ecosystem": "node", "kind": "direct", "name": "widget", "version": "1.1.0", "source": "https://registry.example.invalid/widget"}
  ]
}
```

`id` は依存位置・対象環境を区別する一意で安定した識別子。`component` は `web/worker/ruby-app` 等で `.` は使わない。`ecosystem` は `ruby/node/python`、`kind` は `runtime/direct/transitive/build`。dev/optional/platform 等は ID と根拠で覆う。追加は after のみ、削除は before のみに記録し、after 側の全変更項目と候補 ID を一致させる。同版の ABI 別 wheel 等は正確な `source` 変更として扱い、差分・hash・最新公開日・出所・監査・互換性を確認する。minor は同版・同じ source の metadata 変更を拒否する。

## 検査上限と限界

候補200件、配布物の圧縮済み合計512MiB、候補コピー64MiB・5000項目まで。1配布物128MiB、1メンバー16MiB、展開量128MiB・10000メンバー、JSON/証拠8MiBまで。対応は `.gem`、`.whl/.zip`、`.tar/.tar.gz/.tgz/.tar.xz`。危険なパス・link・特殊形式・構造異常・上限超過・未対応は停止し、通常ファイルへ展開して検査しない。archive の signal がなくても安全判定にはしない。上限・必須項目・待機を外すフラグはない。

同じ UID による意図的な状態/証拠の偽造や直接コマンドの迂回を防ぐ OS 境界ではない。hash は内容の固定であり、公開主体や悪性コードの不存在の証明ではない。確認範囲と残る不確実性を報告する。
