# 供給網の確認を実行ゲートに結びつける

`scripts/supply-chain.py` は Python 3.9 以降の標準ライブラリで動く。更新計画・取得物・監査結果と、根拠付きの手動レビューを結びつけ、条件が揃わない導入を停止する。スクリプトへのパスは対象プロジェクトではなく、このスキルの実体から解決する。`archive_inspector.py`・`audit_report.py` は内部の補助で、これらだけの成功を実行許可に使わない。

このスキル内のランタイム・依存の導入や更新は、必ず `run` を経由する。`check` の成功後に別コマンドで更新する方法、`check && npm install` などの代用、状態ファイルの直接編集、未確認項目の一括 `pass` は使わない。skip・force・公開後の待機期間を短縮する override はない。

## 1. 実行状態と候補を分けて準備する

1. `bash scripts/new-run.sh <project-slug>` の出力を実行記録先 `RUN` とする。ここに `report.md`・`plan.json`・証拠・ゲート状態を置く。対象プロジェクトと候補用コピーから分離し、候補コードや隔離 executor に `RUN` 全体を渡さない。
2. 既存のコンテナ・VM・OS sandbox と executor の実体・設定を静的にレビューする。[隔離条件](verification.md#4-隔離を確認してから導入テスト起動する) を強制できるものを選び、秘密を除いた最小の候補用コピー、専用 cache、ダミー設定を用意する。スクリプトが OS の隔離環境を自動構築・証明することはない。
3. 候補を解決し、配布物を取得する。Gemfile/gemspec・backend・plugin などを評価する解決やメタデータ取得には、この段階からレビュー済みの隔離を適用する。`init` 前ならコードを自由に実行できるという意味ではない。取得と導入を分け、未確認の依存をホストへ導入しない。
4. 更新前後の全依存 inventory、全変更版の公開日時、正確な版・取得元・digest、取得物、機械判定用の監査 JSON を揃える。直接・間接・dev・build・optional・platform 別の範囲を説明し、未探索や監査の非対応を隠さない。Ruby・Node・Python 本体の公式セキュリティ告知も証拠に含める。
5. 計画に候補・manifest・lockfile 相当・実行設定・配布物・inventory・監査結果と、レビュー済みの既存隔離 executor の argv 配列を固定する。executor とその設定・入力も hash で結びつける。shell のコマンド文字列や、未確認の wrapper を実行先にしない。導入時の未確認な再取得・再解決を許さない。

`RUN`・`PROJECT`・`CANDIDATE` は実際の絶対パスを設定する。`UPGRADE_PYTHON` はプロジェクト外の信頼済みPython 3.9以降の実体の絶対パス、`UPGRADE_GATE` はこのスキル実体の `scripts/supply-chain.py` の絶対パスとする。対象のvenv・shim・PATH上の未確認Pythonを使わず、常に `-I -S` で環境由来のimportとsite処理を無効化する。フラグなしの誤用は本体も拒否するが、フラグなしで起動した時点のsite処理まで後から防げるわけではない。

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" init --run "$RUN" --project "$PROJECT" --candidate "$CANDIDATE" --plan "$RUN/plan.json"
```

`init` 後の固定の手動レビューは、すべて `unknown` から始まる。まず `check` を実行し、非ゼロで停止した理由と、機械検査を終えた場合に出力される `automated-checks.json` のsignalを読む。この記録だけで `pass` へ変わらず、各signalの意味と配布物差分のレビューを続ける。

## 2. 固定の7項目を証拠付きでレビューする

| check | `pass` に必要な確認 |
| --- | --- |
| `coverage` | 全依存 inventory と更新差分が manifest・lockfile 相当・platform・dev/build/optional の範囲を覆い、未確認の変更版や取得物が残らない |
| `sources` | 公開元・所有者・repository・配布 URL の連続性、名前の取り違えや取得元の切替を公式の履歴で裏づける |
| `artifacts` | 実際の旧新版配布物の差分、実行 hook・生成コード・通信・秘密へのアクセスを読み、archive 検査の signal と整合する |
| `advisories` | 対応する全依存の監査、DB の鮮度、公式の脆弱性・悪性告知、ランタイムの告知を照合し、対象・期限・未確認点を説明する |
| `authenticity` | 公認の digest、提供された署名・provenance を信頼した公開主体に照合する。未提供の場合は独立した代替根拠と限界を示す |
| `isolation` | executor の実体と argv・設定・入力をレビューし、秘密・ホスト書込み・外部通信・資源の制限と `RUN` の分離を確認する |
| `compatibility` | 正確な更新版と公式の互換性方針、minor / major の境界、ABI・peer・ビルド依存・3言語の連携、検証計画を説明する |

実際の根拠を `RUN` 内の非空ファイルへ保存してから、一件ずつ記録する。`pass` には `--evidence` と説明が必須で、証拠の SHA256・時刻・計画 fingerprint を状態に結びつける。URL だけ、未確認の文章、空ファイルを証拠にしない。秘密や実データも保存しない。

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" review --run "$RUN" --check coverage --status pass --evidence evidence/coverage.md --note "全依存と更新差分を照合した根拠を記録"
```

残る6項目もそれぞれの実際の証拠を用いて同じように記録する。調査できなければ `unknown`、不一致や疑わしい兆候があれば `fail` を記録し、理由と再開条件を示す。

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" review --run "$RUN" --check authenticity --status unknown --note "公開主体を独立した根拠で確認できないため保留"
```

必須項目の `fail`・`unknown` を除外する設定はない。機械検査不能な項目を推測で `pass` にしない。

## 3. 検査を通った計画だけを一度実行する

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" check --run "$RUN"
"$UPGRADE_PYTHON" -I -S "$UPGRADE_GATE" run --run "$RUN"
```

`check`・`run` は、固定の7項目がすべて有効な `pass` でなければ非ゼロで停止する。証拠と監査の有効期間は24時間で、期限切れは再調査する。全変更版の公開から7日未満、公開日時の不明・未来も自動で停止する。組織の方針がより厳しければ追加で守る。緊急修正を理由にこの下限を短縮しない。

自動検査は、全 candidate inventory の差分 coverage、取得物の SHA256、archive の path・link・type・件数とサイズの上限、`.gem` の内層・wheel を含む実行 hook の signal、公開後の日数と minor のランタイム境界を調べる。Ruby・Python 本体の同一 `X.Y`、Node 本体の同一 major でも互換性を自動保証するものではない。

監査 JSON の対応形式は npm audit v2・pip-audit・bundler-audit。エラー・skip・未対応形式・finding が1件でもある結果・期限切れ・coverage 不足は停止する。severity や既存問題を理由に検出結果を無視せず、空の結果を作らない。採用方式のままで対応する監査結果を用意できなければ保留する。署名の信頼・出所・配布物の意味のある差分・DB 鮮度・OS の隔離境界は、証拠付きの手動レビューが必要である。

`run` は実行直前に再検査し、元の対象・候補・manifest・設定・取得物・証拠・executor・hash・argv の差替えを拒否する。レビュー済みの argv 配列を `shell=False` で実行し、計画の実行許可を一度だけ使う。失敗時に同じ状態を流用したり、任意コマンドへ切り替えたりしない。承認はRUNとスキル名にも結びつけ、別のRUNへコピーしても流用できない。候補・入力・計画の変更、再取得・再解決、証拠の差替えや期限切れがあれば、新しい実行記録で準備とレビューをやり直す。

実行後は実際の版・依存・digest を計画と照合し、同じ隔離条件でテスト・必要な実操作を行う。追加の導入や更新が必要なら、別のレビュー済み計画の `run` を経由する。`check`・`run` の結果と残る不確実性も `report.md` に残す。

## 防げる誤りと限界

このゲートは未確認項目・期限切れ・入力差替えを検出して導入手順を停止する補助である。同じ UID の利用者による意図的な状態・証拠の偽造や、直接コマンドを実行する迂回を防ぐ OS の強制境界ではない。hash は内容の固定を示すだけで公開主体の正当性を証明せず、`pass`・`check`・`run` の成功も供給網が無害である保証にはならない。隔離の不足や根拠不足は、静的な調査と差分案を残して保留する。

## 計画JSONとinventoryの形式

JSONは重複キー・未対応キー・不正な型を拒否する。`plan.json`、inventory、監査結果、取得物、隔離設定、証拠はすべて `RUN` 内の通常ファイルとし、symlink・hardlink・特殊ファイルや `..` による参照を使わない。取得元URLから認証情報を除き、認証は取得用プロセスだけに渡す。

次はNodeの1候補を表す構造例。公開日時の `null`、古い監査日時、ゼロのhash、架空のexecutorを含むため実行できない。公式の根拠・実測値・実際の隔離設定で埋め、全候補に展開してから初期化する。初期化後の変更は承認を無効にする。

```json
{
  "schema_version": 1,
  "unit": "web-widget-update",
  "files": ["package.json", "package-lock.json", ".npmrc"],
  "inventory": "inventory.json",
  "candidates": [
    {
      "id": "node:widget",
      "published_at": null,
      "stability": "stable",
      "compatibility": "compatible",
      "artifacts": [
        {
          "path": "packages/widget-1.1.0.tgz",
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
        }
      ]
    }
  ],
  "audits": [
    {
      "ecosystem": "node",
      "component": "web",
      "format": "npm-v2",
      "path": "evidence/npm-audit.json",
      "exit_code": 0,
      "checked_at": "2000-01-01T00:00:00Z"
    }
  ],
  "execution": {
    "mechanism": "container",
    "argv": [
      "/absolute/path/to/reviewed-sandbox-executor",
      "--config",
      "/absolute/RUN/evidence/isolation.json",
      "/absolute/CANDIDATE"
    ],
    "config": "evidence/isolation.json"
  }
}
```

- `unit` は一つの更新単位の説明。majorでは一件の対象と不可分な関連セットを記録する。関連性そのものは `compatibility` と `coverage` の証拠で確認し、文字列があるだけで自動証明したとは扱わない。
- `files` は対象・候補の双方で監視する相対パス。manifest・全lockfile・取得元設定・実行設定・CI等、今回の判断に関わるものを列挙する。指定範囲外の元プロジェクト全体を自動固定したことにはならない。候補コピー全体は別にhashとmodeを固定する。
- `published_at` は公式資料で確認したUTCの `Z` 表記。`stability` は `stable/prerelease/unknown`、`compatibility` は `compatible/migration/unknown`。`unknown` や `prerelease`、minorでの `migration` は停止する。
- `artifacts` はその候補の導入で使う全配布物。公認情報で確認したSHA256と実物を照合する。旧配布物との差分や署名の信頼は、別の必須レビューに根拠を残す。
- `audits` は変更したライブラリ・ビルド依存の各 `ecosystem/component` に対応する実際の監査結果。形式は `node:npm-v2`、`python:pip-audit`、`ruby:bundler-audit`。`checked_at` と `exit_code` は隔離内で実際に実行した日時・終了結果を記録する。これらの申告内容とDB鮮度は `advisories` の証拠でも確認する。bundler-auditはJSON内の生成日時も24時間・未来日時の検査へ含める。
- 本体ランタイムだけの更新は、対応するpackage監査JSONがなくても公式告知を必須の `advisories` で調べる。ライブラリがあるのに報告を省略することはできない。pip-auditは変更したpackageの正規化名・版が結果に含まれるか照合する。npm/bundlerのJSONだけでは全正常依存の解決版を証明できないため、監査範囲は `coverage` でも照合する。
- `execution.argv` は既存隔離executorとその引数。ホストのシェルや依存管理コマンドを直接指定せず、適用される隔離設定と入力・mount・通信制御をレビューする。`mechanism` は `container/vm/os-sandbox`。`config` はその根拠となる実際の設定ファイルで、この宣言だけで隔離が成立するわけではない。cwdは候補コピー、外側executorへ渡す環境は固定のPATH/LANGだけである。

`inventory.json` は全直接・間接・ビルド依存の更新前後の解決結果を記録する。次も構造例であり、実際のmanifest・lockfile・採用ツールの結果を `coverage` で照合する必要がある。

```json
{
  "before": [
    {
      "id": "node:widget",
      "component": "web",
      "ecosystem": "node",
      "kind": "direct",
      "name": "widget",
      "version": "1.0.0",
      "source": "https://registry.example.invalid/widget"
    }
  ],
  "after": [
    {
      "id": "node:widget",
      "component": "web",
      "ecosystem": "node",
      "kind": "direct",
      "name": "widget",
      "version": "1.1.0",
      "source": "https://registry.example.invalid/widget"
    }
  ]
}
```

`id` は依存の位置・対象環境を区別できる一意で安定した識別子。`component` は `web/worker/ruby-app` 等、監査範囲と対応するラベルで、`.` は使わない。`ecosystem` は `ruby/node/python`、`kind` は `runtime/direct/transitive/build`。dev/optional/platform等の違いはIDと証拠で覆う。追加はafterのみ、削除はbeforeのみに記録する。after側で変わった全項目とcandidate IDが一致しなければ初期化できない。inventory自体から全依存を自動発見したことにはしない。

## 検査上限と非対応

- 候補は200件まで、配布物の圧縮済み合計は512MiBまで。候補コピーは `.git` と秘密の `.env*` を除いた最小コピーとし、合計64MiB・ファイルとディレクトリ合計5000件までとする。読めないディレクトリも省略せず停止する。
- 1配布物は128MiBまで、1メンバーは16MiBまで、合計展開量128MiB・10000メンバーまで。検査対応は `.gem`、`.whl/.zip`、`.tar/.tar.gz/.tgz/.tar.xz`。通常ファイルへ展開して検査することはない。
- tarの危険なパス・リンク・特殊形式、zipのCRCや構造異常、暗号化・ZIP64等の未対応形式、上限超過は停止する。gemの既知の内層は検査するが、任意の入れ子archiveはsignalとして示し、追加レビューを必要とする。signalがゼロでも安全判定にはしない。
- 大きな本体バイナリ・wheel等が上限を超える場合も検査を飛ばさない。対象を安全に分割できるか調べ、できなければ未対応として保留する。上限や必須項目を外すフラグはない。
- 監査JSON・証拠は8MiBまで。bundler-auditは確認済みの0.8.x/0.9.xの形式を扱い、未確認の新形式は停止する。実行は30分で待機を打ち切るが、隔離内のプロセス・資源の停止はexecutor側でも強制する。
