# コードを実行する工程の隔離環境を準備する

静的ゲートは Docker・executor を使わない。本手順はコードを評価する候補解決・生成と、任意の導入・テスト・実操作に使う。正しい候補を作れる場合、実行環境の不足だけで静的確認済みの反映を止めない。

Docker 本体の導入・daemon 起動・`sudo`・root 実行・socket の所有者/権限・所属グループ等のホスト設定変更は行わない。準備・probe の成功は供給網レビューの自動承認ではない。

## Docker 接続と Codex の実行承認

Codex のコマンド制限と worker の隔離は別の境界である。ホスト側の信頼済み helper・生成 executor が既存のローカル Docker に接続するため、正規の実行承認を利用できる。

- 通常実行で socket 接続が `permission denied` なら CLI 実体・既存 endpoint・socket を確認し、対象コードを動かさない `docker version` 等を正規承認で再試行する。`sandbox_permissions: require_escalated` 相当があれば目的・接続先を示して使い、要求だけで承認済みとしない。
- Docker はホストへ広く作用できる。レビューしたコード・config・image・worker・全入力の具体的な呼び出しだけを承認対象にし、任意の Docker/Python 操作やプロジェクト wrapper をまとめて許可しない。prepare/probe・execute・専用コンテナの後始末も上位ポリシーと実際の承認結果に従う。
- 承認機構を利用できない・拒否された・承認後も OS が拒否する場合は該当実行を保留する。別経路で迂回せず、通常の拒否だけで Docker 未起動・OS 権限不足と断定しない。対象・依存コードのホスト代行、worker の追加権限・通信や秘密/socket の公開は許可しない。

## 追加検証

1. 静的計画の6レビュー・公開7日待機・`check`・`run` を通し、`check` の binding を確認し、`static-result.json` の `source_manifest` が示す各 snapshot ファイルの hash と実物を照合する。元の可変候補を実行しない。
2. 別の検証用 RUN に、必要な固定 image/配布物と、選択した検証を行う worker を用意する。prepare/probe の結果、helper・生成 executor/config・worker・全入力と実際の隔離境界を事前レビューして証拠を保存する。
3. 下記 `executor execute` で、snapshot・worker・固定配布物だけを渡す。必要な依存導入は scratch 内だけで行い、依存・cache・秘密をホストへ持ち出さない。静的計画へ実行設定や架空の隔離承認を追加しない。
4. コマンド・入力 fingerprint・終了コード・実際の結果と未実施項目を保存する。終了時に環境は消える。未実施だけでは反映完了を取り消さず、更新由来の失敗なら修正または対象を保留する。既存失敗・環境不足と切り分け、失敗を未実施へ書き換えない。
5. 反映後のコード・lockfile 修正は [再確認手順](#反映後に修正が必要になった場合) に従う。未承認の worker 出力を反映しない。ユーザー変更や独立した完了済み更新を巻き込む取り下げはせず、競合と解消案を記録して停止する。

### 反映後に修正が必要になった場合

反映済みの版・取得元のままソースだけを修正しても inventory に変更候補がなく、ゲートは新規計画を初期化できない。未反映なら取り下げは不要で、現在の対象から修正済み候補を新しい RUN で作る。既に反映した対象は次の順に扱う。

1. 保存した元 bytes/逆差分・元 mode・更新前 inventory・反映差分から、取り下げる境界を依存関係で特定する。反映後の hash/mode と現在の内容を照合し、ユーザー変更や別の更新との重複を確認する。
2. 当該更新で自分が反映した分だけを安全に取り下げ、その対象の更新前グラフを実際のプロジェクトへ復元する。独立した更新やユーザー変更を戻さず、lockfile・環境指定も整合させる。安全に分離できなければ具体的な競合・解消案・未解消状態を記録して停止する。
3. 復元後の実際の対象を新しい初期状態にし、新 RUN と候補コピーを作る。目標版への更新とソース修正を含めて候補を完成させ、実際の before → after inventory・全配布物・根拠を固定する。6レビュー・7日待機・`check`・静的 `run` を確認し直す。古い承認・失敗した RUN を流用しない。
4. 初期状態を照合して修正済み差分を反映し、必要な任意検証は別の新しい RUN で行う。元の失敗と修正後の結果を区別する。

## 1. image と worker を準備する

対象の指示・CI・manifest/lockfile から OS/arch・ランタイム・管理方式・native build の条件を決める。公式配布情報から公認 image の公開元・版・toolchain・platform と digest を調べ、`repository@sha256:<64桁>` に固定する。可変 tag・未確認のツール自動取得・対象 Dockerfile の無条件 build は使わない。

`RUN/sandbox/worker.sh` はレビュー済み `/bin/sh` スクリプトとし、`set -eu` で始める。`if`・`&&`・pipeline 等の例外を確認し、`tee` 等で必須処理の失敗を隠さない。処理・固定入力・終了コード・証拠保存を決め、未確認の hook や外部サービスへ接続しない。候補解決・基準検証・追加検証は worker・入力・出力を分ける。異なる runtime image を使う場合は別 RUN で準備する。

native 拡張の静的確認では ABI・wheel/platform・headers/toolchain の対応を照合して未実測と明記する。実行検証では compiler・headers・linker・build tool を含む image と固定ソースで再ビルド・ロードする。旧 ABI の `.so` や依存ディレクトリを持ち込まない。SDK を worker 内で取得せず、不足なら image を選び直す。同版の別配布物も正確な source/hash と最新公開日を確認する。

## 2. 設定と executor を自動生成する

`UPGRADE_PYTHON` はプロジェクト外の信頼済み Python 3.9 以降の実体、`UPGRADE_SANDBOX` は同梱 helper の絶対パス、`UPGRADE_IMAGE` は確認した digest 固定参照。`RUN` は同梱 `new-run.sh` の記録先を使う。

```bash
"$UPGRADE_PYTHON" -I -S "$UPGRADE_SANDBOX" prepare \
  --run "$RUN" --image "$UPGRADE_IMAGE" --worker sandbox/worker.sh
```

必要なら `--docker <CLI実体の絶対パス>`・`--context <既存のローカルcontext>` を指定する。既存 CLI とローカル daemon/context を検出し、未取得 image は digest 付きで取得する。取得時に対象コードは実行しない。設定・executor・probe 証拠を生成し、既存設定は上書きしない。

| 保存先 | 用途 |
| --- | --- |
| `RUN/sandbox/config.json` | 固定 image・接続先・実行ユーザー・資源上限 |
| `RUN/sandbox/executor` | 任意検証や候補解決で使う実行プログラム |
| `RUN/evidence/isolation-setup.json` | probe の結果。事前レビューの根拠の一部 |

生成物・image・worker と実際の境界を読み、公開する入力を確認する。static 計画に統合する実行設定は生成しない。実測した runtime/toolchain の版は inventory の指定と区別して記録し、検証対象の版と照合する。

## 3. worker と入力・出力の契約

- 読み取り専用 `/candidate` を隔離内の `/scratch/project` へコピーし、worker は `CANDIDATE=/scratch/project`、`OUTPUT=/scratch/output` を使う。元のホストパスを組み立てない。
- `--input <固定ファイル実体>` は指定順に `/inputs/0` 等へ読み取り専用で渡る。配布物と補助ファイルの必要分だけを直接指定し、静的計画へ実行引数を追加しない。拡張子・basename が必要なら scratch 内の所定名へコピーして使う。
- `.git`・秘密・実データ・HOME・認証設定・SSH agent・Docker socket を渡さない。環境変数は許可リストだけで、使い捨て HOME/tmp/cache と専用作業領域を使う。
- rootfs と入力は読み取り専用、通信と追加権限を禁止し、CPU・メモリ・process・ディスク・時間を制限する。scratch は容量制限付きで native code を実行できる。出力は安全に検査した通常ファイルだけを専用先へ保存し、ホスト出力を worker へ書込み可能 mount しない。
- worker は失敗を終了コードへ伝える。標準出力/標準エラーは `worker.log`、終了コードは `exit-code` に保存されるので、この名前を成果物に使わない。終了時にコンテナと scratch が消えるため、必要な検証と証拠保存を一回の worker 内で完了する。

## 4. 準備段階と対応できない工程

コードを評価する候補解決・生成、必要な展開、選択した基準検証はゲート初期化前でもレビュー済み executor と同じ隔離条件で行う。元のプロジェクトや RUN 全体を公開しない。準備環境の依存や未確認出力を対象へ反映せず、完成した候補を静的ゲートで確認する。基準用は固定した旧版グラフ・現在版を照合して測り、候補解決と混同しない。

`PREP_RUN` は準備済み記録先、`PREP_INPUT` は秘密を除いて固定した候補または承認済み snapshot、`PREP_WORKER` はレビューした worker、`PREP_OUTPUT` は空で所有者だけがアクセスできる専用先とする。

```bash
"$PREP_RUN/sandbox/executor" execute \
  --config "$PREP_RUN/sandbox/config.json" --candidate "$PREP_INPUT" \
  --worker "$PREP_WORKER" --output "$PREP_OUTPUT"
```

コード評価なしの固定配布物取得・[監査照会](#5-対象コードを実行しない監査照会)は対象コードを実行しないプロセスで行える。コード評価と通信の両方が必要、または評価を排除できるか不明なら、秘密を渡さず送信先を限定できる既存の取得専用隔離が必要。同梱の外部通信禁止を解除せず、用意できなければ該当工程を保留する。

同梱 executor はオフライン処理向けで、ポート公開・DB 連携・ブラウザ/ネイティブ OS の操作を自動準備しない。必要なら [隔離条件](verification.md#4-隔離を確認してから導入テスト起動する) を満たす既存環境で、選択した検証を完了まで維持する。用意できなければ検証を未実施とし、正しい候補と静的根拠が揃った反映は完了できる。ホストへの依存持出し・対象コード代行・制限解除で回避しない。

## 5. 対象コードを実行しない監査照会

- 信頼済みの audit ツールとランタイムを使い、必要な環境だけを空から許可する。使い捨て HOME/cache・データ専用作業場と、秘密を除いた manifest/lockfile/全依存 inventory だけを使う。
- 元プロジェクト内で起動せず、ユーザー/プロジェクトの設定・plugin・hook・wrapper を読み込まない。対象・依存コードの評価、再解決・導入・修復を行わないことを使用版の仕様と起動経路で確認する。
- 送信先・内容を確認し、private 名・認証情報を無断送信しない。無加工 JSON、実測の時刻・終了コード・ツール版・範囲と実行条件を記録する。
- 全更新後ライブラリ・ビルド依存を覆い、ランタイムだけの変更でも既存依存を省略しない。finding・skip・coverage・24時間の期限は [ゲート](gate.md) と同じ。ツールのゼロ件だけで安全判定しない。

通常の npm audit は、使用版で対象コードを評価しない条件を確認できればこの照会に含められる。`audit fix` は導入処理を含むため使わない。取得/監査にコード評価が必要なら送信先制限付き隔離を使い、不可なら該当処理を保留する。JSON 未収集分は全対象の公式告知・advisory DB 照会で確認できるか検討する。

## 6. 検証した差分を保存して対象へ反映する

最終内容は静的 `run` の `execution-inputs/candidate` と `execution-output/static-result.json` の `source_manifest` を使う。親側のデータ処理・ファイル比較で初期状態との全差分と payload を用意し、worker に差分生成を要求しない。

1. 候補編集前に許可するソース範囲と全反映予定パスを宣言し、範囲内の全ファイル/ディレクトリの有無・hash・mode を完全な基準 manifest として RUN に保存する。追加予定の不存在も確認し、秘密・依存・cache を除く。反映前に変更/削除予定の元 bytes または逆差分と元 mode も保存し、初期 hash と照合する。後から未宣言の反映パスが必要になれば新 RUN で計画し直す。`plan.files` 外のソースもこの契約で保護する。
2. snapshot 全体の hash を `source_manifest` と照合し、初期状態からの追加・変更・削除・rename を、前後の有無・SHA256・必要な実行 bit 付きの patch、または変更 manifest と最終内容として記録する。元 mode は `source_manifest` を使い、snapshot の `0400`/`0500` や保存出力の `0600` を採用権限にしない。
3. 宣言済み範囲・変更前の基準・保存内容と変更後 hash を照合し、symlink・特殊ファイル・危険なパス・未宣言パス・依存・cache・秘密を拒否する。
4. 全適用予定パスの現在の有無・bytes/hash・実行 bit を初期記録と再照合し、親ディレクトリを含む symlink も拒否する。一件でも不一致なら全件の適用を開始せず、ユーザー変更を保持して新 RUN で調整する。ゲートの実行前検査だけで代用しない。
5. 許可差分だけを既存の編集/patch 手順で反映し、明示変更以外の既存権限を保つ。適用中の競合・失敗は適用済み/未適用を記録して停止し、一括 rollback でユーザー変更を巻き込まない。全パスの更新後 hash・実行 bit・削除を照合するまで反映完了にしない。

## 公式資料

- [Docker の実行制御](https://docs.docker.com/engine/containers/run/)
- [tmpfs の容量とライフサイクル](https://docs.docker.com/engine/storage/tmpfs/)
- [外部通信を持たない none network](https://docs.docker.com/engine/network/drivers/none/)
