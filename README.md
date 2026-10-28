# agent-skills

Claude Code で開発し、Codex で整備するための汎用スキル集。特定のプロジェクトに依存せず、普段の仕事で使う。

- [Claude で開発し、Codex で整備する](#claude-で開発しcodex-で整備する)
- [はじめに](#はじめに)
- [Claude Code 用スキル一覧](#claude-code-用スキル一覧)
- [Codex 用スキル一覧](#codex-用スキル一覧)
- [実行結果の保存先](#実行結果の保存先)
- [スキルの追加・変更](#スキルの追加変更)

## Claude で開発し、Codex で整備する

Claude Code のスキルは機能を作って届けるまでの開発を、Codex のスキルは開発で積み上がったコードベースを整える保守や、書類など日常のファイル整理を受け持つ。

| | Claude Code | Codex |
| --- | --- | --- |
| 役割 | 開発する | 整備する |
| 扱う作業 | Issue の把握・設計・実装・テスト・レビュー・PR の確認・次の作業の判断 | 設計方針への整合、責務分割・共通化、宣言順の整理、テストの整理、文書同期、実行・開発環境と依存の更新、内容に基づくファイル名の整理 |
| 変更の性質 | 機能や振る舞いを追加・変更する | 整備では既存の振る舞いを保ち、更新では互換性と供給網を確認して必要な移行を行う |
| 使い方 | 条件に当たると Claude が自分の判断で使うスキルが中心 | `$スキル名` で明示的に指定したときだけ使う |

典型的な流れは次のとおり。

1. **Claude Code で開発する**: 設計・実装・検証を進め、PR まで仕上げる。実装・テスト・レビューの一部は Claude のスキルが Codex CLI（GPT-6 Luna / GPT-6.1 Sol / GPT-6 Astra）に任せるが、指示・採否の判断・反映は Claude が行う。
2. **Codex で整備する**: 時間やトークンに余裕があるとき、プロジェクト全体の設計とのずれ・責務の混在や重複・冗長なテスト・宣言順・古いドキュメントを繰り返し整える。`$codebase-cleanup-workflow` でまとめて実行するか、目的ごとのスキルを指定する。ランタイム・依存の更新は別途 `$minor-version-upgrade` / `$major-version-upgrade` で依頼し、静的確認で反映し、利用可能な環境でテスト・画面操作を追加する。
3. **整ったコードベースで、また Claude Code で次の開発に進む。**

## はじめに

### 1. ユーザー用ディレクトリへリンクする

他のプロジェクトでも使えるよう、リポジトリ直下で実行する。

```bash
# Claude Code と Codex の両方
scripts/link-skills.sh

# 片方だけ使う場合
scripts/link-skills.sh --claude
scripts/link-skills.sh --codex
```

| エージェント | このリポジトリの配置 | ユーザー用リンク先 | 呼び出し方 |
| --- | --- | --- | --- |
| Claude Code | `.claude/skills/` | `~/.claude/skills/` | `/スキル名` |
| Codex | `.agents/skills/` | `~/.agents/skills/` | `$スキル名` |

Claude Code のリンク先は、`CLAUDE_CONFIG_DIR` 指定時はその配下の `skills/` になる。Codex の配置先は [公式スキルドキュメント](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) を参照。追加が反映されなければ Codex を再起動する。

- 引数なし、または `--all` で両方をリンクする。各エージェントのスキルは、対応するリンク先だけに配置する。
- スキルの追加・改名・削除やリポジトリの移動後は再実行する。新しいスキルをリンクし、このリポジトリの削除済みスキルへの切れたリンクを削除する。移動前の場所を指す切れたリンクは張り直す。
- 同名のファイル・ディレクトリや、別の場所への有効なリンクは上書きしない。
- git worktree からは実行せず、メインの checkout で実行する。worktree では変更せず、実行場所を案内する。

### 2. 使う準備を確認する

利用するエージェントで `skills-preflight` を呼び出す。確認だけを行い、インストール・ログイン・リンクの変更は行わない。

| エージェント | 呼び出し | 確認すること |
| --- | --- | --- |
| Claude Code | `/skills-preflight` | Claude Code スキルに必要なコマンド・ログイン・ユーザー用リンクと、不足への対処 |
| Codex | `$skills-preflight` | Codex スキルの定義・呼び出し設定・リンク、必要なコマンド、対象プロジェクトの検証環境 |

### 3. 目的に合うスキルを選ぶ

開発には Claude Code 用、整備・更新・ファイル整理には Codex 用の一覧から選ぶ。名前のリンクから詳細な手順・オプションを確認できる。各一覧は、コードベースの開発・整備に使う**開発用スキル**と、準備確認・報告・情報収集・ファイル整理などに使う**雑務用スキル**に分けている。Claude Code のスキルはさらに呼び出し方で分類し、開発用は各分類の中を設計・実装・検証・仕上げの作業順に並べている。Codex の開発用スキルは更新・一括整備のあと、設計・構造・テスト・宣言順・文書の順に並べている。

## Claude Code 用スキル一覧

開発を進めるための[開発用スキル](#claude-code-の開発用スキル)と、準備確認・報告・情報収集などの[雑務用スキル](#claude-code-の雑務用スキル)がある。呼び出し方は次の3種類。自動で使う条件・確認される条件は、各一覧で機能と分けて示す。

| 種類 | 呼び出し方 | 開発用 | 雑務用 |
| --- | --- | --- | --- |
| 自動で使われる | 条件に当たると Claude が使う。`/スキル名` や話しかけても使える | [codex-design-review・codex-impl・codex-test・codex-impl-review・opus-final-review](#自動で使われる開発用スキル) | [japanese-report・session-status-emoji](#自動で使われる雑務用スキル) |
| 使う前に確認される | 条件に当たると使うか確認する。`/スキル名` や話しかけても使える | [codex-risk-design-review・codex-risk-impl-review](#使う前に確認される開発用スキル) | なし |
| 明示的に呼び出す | `/スキル名` で指定して使う。通常の依頼から自動で選ぶことはない | [gh-issue-overview・codex-verify-prompt・gh-pr-precheck・whats-next](#明示的に呼び出す開発用スキル) | [skills-preflight・gh-todo・browser-readonly-research](#明示的に呼び出す雑務用スキル) |

### Claude Code の開発用スキル

設計・実装・テスト・レビュー・PR の確認・次の作業の判断など、機能を作って届けるまでの開発に使う。

#### 自動で使われる開発用スキル

条件に当たると Claude が自分の判断で使う。`/スキル名` や自然な言葉で明示的に依頼することもできる。

| スキル | できること | 自動で使う条件 | 使い方の例 | 前提 |
| --- | --- | --- | --- | --- |
| [codex-design-review](.claude/skills/codex-design-review/SKILL.md) | 設計を Codex CLI の GPT-6.1 Sol に読み取り専用でレビューさせ、Claude が指摘の採否を判断して修正案を出す。`--focus` で観点ごとに並列化できる | 3 ファイル以上・新しい機能や API・複数案から選んだ設計や、DB・公開 API・認証・課金などに触れる設計を提示する前（迷ったら使う。1〜2 ファイルの局所的な変更は除く）。基本は Sol 1 本で、新しいモジュールを 2 つ以上作るか 10 ファイル以上に手を入れる設計、DB・認証・課金などの高リスク領域に 2 つ以上触れる設計のときだけ、観点ごとに 2〜3 本並列にする | `/codex-design-review`<br>`/codex-design-review --focus requirements,reliability docs/design.md`<br>「この設計を Codex にレビューしてもらって」 | `codex` にログイン済み、`jq` |
| [codex-impl](.claude/skills/codex-impl/SKILL.md) | 実装を Codex CLI の GPT-6 Luna（推論レベル max・Fast モード）に任せ、Claude は分割・指示・レビュー・反映を行う。独立したタスクは worktree で並行実装する。DB や Docker が要るテストは `--test` でサンドボックスの外で実行し、失敗したら自動で Luna に差し戻す。サンドボックスはネットワークなし、コミットはしない | 要件と完了の条件がはっきりした 250 行以上の部分（既存パターンに沿った機能追加、テスト追加など）に取りかかるとき（250 行以上なら迷ったら任せる。250 行未満は Claude が書く） | `/codex-impl CSV エクスポートを追加して`<br>「この Issue の実装を Luna に並列で任せて」<br>「トークン節約で Codex に実装させてレビューして」 | `codex` にログイン済み、`jq`、対象が git リポジトリ（`--test` には perl） |
| [codex-test](.claude/skills/codex-test/SKILL.md) | テスト・型チェック・lint・ビルドを GPT-6 Luna（推論レベル max・通常速度）に実行させ、失敗の要点と原因を報告させる。ファイルは変更しない。`--resume` で再実行、`--network` でネットワークを許可できる | Claude がテスト・型チェック・リンター・ビルドを実行するときは原則すべて。実装の確認、完了報告・コミット・PR の前、失敗の切り分けでは必ず任せる（迷ったら任せる。数行で済む 1〜数件のテストを編集のたびに細かく繰り返している最中だけは Claude が直接実行する） | `/codex-test`<br>`/codex-test npm test と型チェックを実行`<br>「テストして」 | `codex` にログイン済み、`jq` |
| [codex-impl-review](.claude/skills/codex-impl-review/SKILL.md) | git の差分を GPT-6.1 Sol に読み取り専用でレビューさせ、Claude が指摘の採否を判断し、自分の実装なら修正する。既定は未コミットを含む既定ブランチとの差分。`--base` / `--commit` / `--uncommitted` と `--focus` で範囲・観点を選べる | 2 ファイル以上か 30 行以上のロジック変更や、DB・公開 API・認証・課金などに触れる変更を終えたら、完了報告やコミットの前（迷ったら使う。数行の変更やドキュメントだけの変更は除く）。基本は Sol 1 本で、15 ファイル以上か 500 行以上の変更、DB・認証・課金などの高リスク領域に 2 つ以上触れる変更のときだけ、観点ごとに 2〜3 本並列にする（この 2 つでは仕上げに opus-final-review も使う） | `/codex-impl-review`<br>`/codex-impl-review --fast --uncommitted`<br>「観点ごとに分けて Codex で並列に実装レビューして」 | `codex` にログイン済み、`jq`、対象が git リポジトリ |
| [opus-final-review](.claude/skills/opus-final-review/SKILL.md) | 会話を共有しない別の Claude（Opus 5.5）に、要件と git の差分だけで最終レビューさせる。別セッションは設定・MCP・スキルを読み込まず、読み取り専用で確認する。Claude が指摘の採否を判断し、自分の実装なら修正する | 15 ファイル以上か 500 行以上の変更、または DB・認証・課金などの高リスク領域に 2 つ以上触れる変更で、codex-impl-review などの指摘を直し終えたあとの最後の確認（Claude の使用量になるので、迷ったら使わない） | `/opus-final-review`<br>`/opus-final-review --uncommitted`<br>「仕上げにコンテキストなしの Opus で最終レビューして」 | `claude` にログイン済み、`jq`、対象が git リポジトリ |

Sol / Astra のレビューと Opus の最終レビューは、推論レベルを現在の Claude に揃える。Sol / Astra は `--fast` にも対応する。並列化やレビュー範囲の詳しい指定は、各スキルを参照。

#### 使う前に確認される開発用スキル

リスクの高い設計・実装を扱うときに、使うか確認してから実行する。`/スキル名` や自然な言葉で明示的に依頼することもできる。

| スキル | できること | 確認される条件 | 使い方の例 | 前提 |
| --- | --- | --- | --- | --- |
| [codex-risk-design-review](.claude/skills/codex-risk-design-review/SKILL.md) | 戻しにくい設計を GPT-6 Astra に「どう壊れるか」の観点でレビューさせる。データ・認可・並行処理・課金・外部への副作用・移行を重点的に確認し、Claude が採否を判断して修正案を出す | DB 移行・認可・課金・外部への送信など、壊れると影響が大きく戻しにくい設計を提示・実装する前 | `/codex-risk-design-review`<br>`/codex-risk-design-review --fast docs/design.md`<br>「実装前にこの設計を Astra でレビューして」 | `codex` にログイン済み（Astra が使えるプラン）、`jq`、codex-design-review スキル（スクリプトを共有） |
| [codex-risk-impl-review](.claude/skills/codex-risk-impl-review/SKILL.md) | リスクの高い実装の差分を GPT-6 Astra にレビューさせ、データの破損・認可・並行処理・課金・互換性・失敗時の動きを確認する。Claude が採否を判断し、自分の実装なら修正する | DB 移行・認可・課金・外部への送信など、壊れると影響が大きく戻しにくい変更の完了報告やコミットの前 | `/codex-risk-impl-review`<br>`/codex-risk-impl-review --fast --uncommitted`<br>「本番に出す前に Astra でレビューして」 | `codex` にログイン済み（Astra が使えるプラン）、`jq`、対象が git リポジトリ、codex-impl-review スキル（スクリプトを共有） |

#### 明示的に呼び出す開発用スキル

`/スキル名` で指定して使う。話しかけただけで起動したり、Claude が自分の判断で使ったりすることはない。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [gh-issue-overview](.claude/skills/gh-issue-overview/SKILL.md) | Issue を調べ、前提・5W1H・全体像の図・進め方を実装計画の概要にまとめ、組み込みブラウザに表示する。細かい実装には踏み込まない | `/gh-issue-overview <Issue の URL>`<br>`/gh-issue-overview <Issue の URL> バックエンドだけ` | `gh` にログイン済み、`python3` |
| [codex-verify-prompt](.claude/skills/codex-verify-prompt/SKILL.md) | PR または会話と作業中の変更から、Codex に渡す動作確認プロンプトを作る。手順・期待結果・副作用を避ける決まり・報告形式を含める。`--browser builtin` / `--browser chrome` は必須。検証環境を省略するとローカルの起動手順を調べる。Codex やアプリは起動しない | `/codex-verify-prompt --browser builtin <PR の URL> <検証環境の URL>`<br>`/codex-verify-prompt --browser chrome <PR の URL>`<br>`/codex-verify-prompt --browser builtin https://staging.example.com ログイン周りだけ` | `git`、`jq`（PR を渡すときは `gh` にログイン済み） |
| [gh-pr-precheck](.claude/skills/gh-pr-precheck/SKILL.md) | Issue の要件とプロジェクトの方針に PR を照合し、CI・コンフリクト・未解決レビューも含め、人間のレビューに進めるか判定する。PR 省略時は関連する PR を探す。コード変更や GitHub への書き込みは行わない | `/gh-pr-precheck <Issue の URL>`<br>`/gh-pr-precheck <Issue の URL> <PR の URL>` | `gh` にログイン済み、`jq`、`curl`、gh-issue-overview スキル（スクリプトを共有） |
| [whats-next](.claude/skills/whats-next/SKILL.md) | 会話と実際のブランチ・差分・PR の状態から、進捗と次のアクションを1つ示す。実行手順または選択肢を提案し、承認後にその範囲だけ進める。デスクトップでは返事のボタンも表示する | `/whats-next`<br>`/whats-next 今日は 30 分だけ` | なし（ボタンは Claude デスクトップアプリ（Code タブ）。PR の状態は `gh` にログイン済みのときだけ） |

### Claude Code の雑務用スキル

使う準備の確認、報告の書き方、セッションの見分け、GitHub の TODO の把握、Web ページの調査など、開発そのもの以外の作業に使う。

#### 自動で使われる雑務用スキル

条件に当たると Claude が自分の判断で使う。`/スキル名` や自然な言葉で明示的に依頼することもできる。

| スキル | できること | 自動で使う条件 | 使い方の例 | 前提 |
| --- | --- | --- | --- | --- |
| [japanese-report](.claude/skills/japanese-report/SKILL.md) | 報告・調査結果・確認を、見出しまで自然な日本語で書く。英語の出力も日本語で要約し、識別子・コマンド・エラー原文は維持する。コミットや PR 本文はリポジトリの慣習に従う | Claude が結果を報告する前（とくに英語の材料をもとに書くとき） | `/japanese-report`<br>「さっきの報告を日本語で書き直して」<br>「日本語で報告して」 | なし |
| [session-status-emoji](.claude/skills/session-status-emoji/SKILL.md) | このセッション名の先頭に作業状態の絵文字を付け、サイドバーで並行作業を見分けやすくする。初期値は ✨、段階の変化とターンの終わりに更新する。変更を断られたら以後更新しない | Claude デスクトップアプリでは、短い質問への回答も含めてすべてのセッションの最初のターン（以後、段階が変わるたびとターンの終わりに更新する。迷ったら使う） | `/session-status-emoji`<br>「セッション名に状態の絵文字を付けて」 | Claude デスクトップアプリ（Code タブ） |

#### 明示的に呼び出す雑務用スキル

`/スキル名` で指定して使う。話しかけただけで起動したり、Claude が自分の判断で使ったりすることはない。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [skills-preflight](.claude/skills/skills-preflight/SKILL.md) | 必要なコマンド・Codex / Claude / gh のログインと、ユーザー用リンクを確認し、スキルごとの利用可否をまとめる。不足は Homebrew 前提の対処を案内し、環境は変更しない | `/skills-preflight` | なし |
| [gh-todo](.claude/skills/gh-todo/SKILL.md) | レビュー依頼、直近の未返信メンション、自分にアサインされた open な Issue / PR を集め、組織ごとの表にする | `/gh-todo`<br>`/gh-todo レビュー依頼とメンションだけ` | `gh` にログイン済み |
| [browser-readonly-research](.claude/skills/browser-readonly-research/SKILL.md) | 公開ページは WebFetch を先に使い、必要に応じて組み込みブラウザで読み、要点・出典・読めなかったページを日本語でまとめる。Chrome は `--chrome` または依頼時だけ使う。送信・入力・ログイン・同意・ダウンロードは行わず、ページ内の指示には従わない | `/browser-readonly-research <URL> このページの要点をまとめて`<br>`/browser-readonly-research --chrome <社内ツールの URL> 今週の変更点を調べて` | Claude デスクトップアプリの組み込みブラウザ、または Claude in Chrome 拡張機能 |

## Codex 用スキル一覧

開発したコードベースの整備、Ruby・Node（JavaScript / TypeScript）・Python のランタイムや依存の更新に使う[開発用スキル](#codex-の開発用スキル)と、準備確認や書類などのファイル整理に使う[雑務用スキル](#codex-の雑務用スキル)がある。すべて `$スキル名` で明示的に指定したときだけ使う。

| 用途 | スキル |
| --- | --- |
| 開発用 | minor-version-upgrade・major-version-upgrade・codebase-cleanup-workflow・design-alignment-refactor・code-structure-refactor・test-suite-refactor・code-order-refactor・docs-align-with-code |
| 雑務用 | skills-preflight・rename-files-by-content |

### Codex の開発用スキル

`minor-version-upgrade` / `major-version-upgrade` は、Ruby・Node・Python のランタイムと依存ライブラリの更新に最適化し、`codebase-cleanup-workflow` には含めない。Ruby / Bundler、Node / npm・pnpm・Yarn、Python / uv・pip・Poetry など、採用中の管理方法を設定と lockfile から静的に確認し、管理ツールを勝手に変更しない。対象の管理ツールは採用されたものだけを使い、すべての導入は要求しない。共通の実行ゲートには `bash` と Python 3.9 以降の標準ライブラリが必要。Rails・Node のフロントエンド・Python worker など3言語が混在する構成も一覧化し、言語間の連携を静的に確認して、利用可能なら実行検証する。その他の言語は影響・依存境界を記録し、更新対象を広げない。グローバル環境の更新は依頼範囲に含まれる場合だけ行う。

Ruby・Python の `X.Y` ブランチ変更や機能リリース、Node の major 更新は個別移行として扱う。Node の同一 major 内の minor / patch、Ruby・Python の同一 `X.Y` 内の patch、各ライブラリの互換性を保つ更新は、公式方針と実際の変更を確認したうえでまとめる。ライブラリも番号だけで判断せず、`0.x` の minor 増加や非互換変更を含む版は個別に扱う。同版の ABI 別 wheel 等への切替も実際の `source` 変更として記録し、新旧配布物の差分・hash・公開日・出所・監査・互換性を確認する。同版を安全とせず、互換性不明なら個別移行へ回す。

更新は [minor の静的ゲート](.agents/skills/minor-version-upgrade/references/gate.md) / [major の静的ゲート](.agents/skills/major-version-upgrade/references/gate.md) の静的確認に統一する。正しい manifest・lockfile・環境指定・必要な移行ソースを用意し、`coverage`・`sources`・`artifacts`・`advisories`・`authenticity`・`compatibility` の6項目を根拠付きで確認して反映する。`schema_version: 2` の計画はモード指定不要で、ゲートは executor や Docker を起動しない。

候補版と全新規配布物（wheel・image 等）の最新の公式公開日時から **7日以上** を必須にする。同版の新規配布物を版の古い初回公開日で代用せず、7日未満・日時不明・未来は保留する。最新安定版が新しすぎれば経過済みの適切な安定版を選び、なければ再開可能日または不明の理由を報告する。緊急修正でも短縮せず、待機を外す override はない。

更新後 inventory の全ライブラリ・ビルド依存とランタイムの既知情報を確認し、ランタイムだけの変更でも既存依存を省略しない。JSON 未収集分は全対象版への公式告知/advisory DB の照会を証拠化できるが、提示済み監査の finding・error・skip・期限切れ・coverage 不足は無視しない。静的根拠や正しい候補を用意できない対象、明確な非互換・更新由来のテスト失敗は修正または保留する。証拠・監査は24時間で期限切れとなり、入力・根拠の変更は新 RUN で確認し直す。

`run` は対象コードを実行せず、承認済み候補の readonly snapshot と元の hash/mode を保存する。[保存・反映契約](.agents/skills/minor-version-upgrade/references/isolation.md#6-検証した差分を保存して対象へ反映する)で元の全適用予定パスを照合し、競合がなければ追加・変更・削除・実行 bit を反映する。snapshot の権限を採用権限に使わない。反映前に元 bytes/逆差分も保存し、反映後の修正は自分の当該更新分だけを安全に取り下げ、実際の更新前グラフから修正済み候補を新 RUN で確認する。

導入・テスト・lint・ビルド・実操作は利用可能な場合の任意検証として残し、未実施の工程・理由と実際の成功/失敗を報告する。コード評価を伴う解決・生成や検証は [隔離手順](.agents/skills/minor-version-upgrade/references/isolation.md) を適用し、Docker は既存環境上に同梱 helper で準備できる。正規の Codex 接続承認を利用しつつ、worker の通信・権限・資源・秘密の制限を維持する。ホストでの対象コード代行や Docker 導入・daemon 起動・socket 権限変更は行わない。正しい候補作成に実行が不要なら、Docker・テスト・ブラウザの不足だけで反映を止めない。

静的確認済みと実行時の動作確認済みを区別し、未確認を成功扱いにしない。ゲートは OS の強制境界や攻撃の不存在の保証ではない。

整備スキルは、気が向いたときや時間・トークンに余裕があるときに、既存の振る舞いを保ってプロジェクト全体を繰り返し整えるために使う。対象を省略すると全体を探索し、指定した場合はその範囲を扱う。有益な変更がなければそのまま終え、未探索・保留・未検証の範囲を報告する。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [minor-version-upgrade](.agents/skills/minor-version-upgrade/SKILL.md) | Ruby・Node・Python の互換更新をまとめ、候補版・全新規配布物の公開から7日以上を必須にして静的確認後に反映する。テスト・実操作は利用可能な場合に追加する | `$minor-version-upgrade`<br>`$minor-version-upgrade Ruby・Node・Python と依存を互換性を保つ範囲でまとめて更新して` | `bash`、Python 3.9 以降、公式情報・配布物と正しい候補・lockfile を確認できること。コード評価が必要な候補作成・追加検証には条件を満たす隔離環境 |
| [major-version-upgrade](.agents/skills/major-version-upgrade/SKILL.md) | Ruby・Python の系列変更、Node や依存の major 更新を一件ずつ移行し、候補版・全新規配布物の公開から7日以上を必須にして静的確認後に反映する。実行検証は利用可能な場合に行う | `$major-version-upgrade`<br>`$major-version-upgrade Ruby・Node・Python のランタイムと依存を一件ずつ移行して` | `bash`、Python 3.9 以降、公式の移行・供給網情報と正しい候補・lockfile を確認できること。コード評価が必要な候補作成・追加検証には条件を満たす隔離環境 |
| [codebase-cleanup-workflow](.agents/skills/codebase-cleanup-workflow/SKILL.md) | 全体探索と検証結果を共有し、設計整合 → 責務分割・共通化 → テスト整理 → 宣言順整理 → 文書同期を一巡する。各スキルの判断基準で必要な改善を実施する | `$codebase-cleanup-workflow`<br>`$codebase-cleanup-workflow 今回は src/billing のみ整備して` | 下記5つの整備スキルを参照でき、対象の実装・文書と検証環境を利用できること |
| [design-alignment-refactor](.agents/skills/design-alignment-refactor/SKILL.md) | 文書とコードからプロジェクトの設計方針を読み取り、責務分担や依存関係の逸脱を修正する。意図的な例外を尊重し、既存の振る舞いを保って検証する | `$design-alignment-refactor`<br>`$design-alignment-refactor src/billing をプロジェクトの設計に合わせてリファクタリングして` | 対象の設計・実装を参照でき、関連する検証を実行できること |
| [code-structure-refactor](.agents/skills/code-structure-refactor/SKILL.md) | 責務の混在や重複を探索し、責務分割・共通化で保守性・可読性・拡張性を改善する。既存の振る舞いを保ち、効果のない抽象化を避ける | `$code-structure-refactor`<br>`$code-structure-refactor src/billing の責務分割と共通化を進めて` | 対象の実装を参照でき、関連する検証を実行できること |
| [test-suite-refactor](.agents/skills/test-suite-refactor/SKILL.md) | 不具合の検出力を保ちながら、重複や実装の細部に依存するテストを削除・統合・書き換える。境界値・異常系・過去の不具合・重要な副作用を守り、影響範囲を実行して確かめる | `$test-suite-refactor`<br>`$test-suite-refactor src/billing のテストを整理して` | 対象リポジトリのテスト実行環境 |
| [code-order-refactor](.agents/skills/code-order-refactor/SKILL.md) | プロジェクトを探索し、メソッド・関数などを読みやすい順へ移す。初期化・登録などの順序依存を守り、再実行でも配置を安定させる | `$code-order-refactor`<br>`$code-order-refactor src/billing のメソッドの順番を整理して` | 対象の実装を参照でき、関連する検証を実行できること |
| [docs-align-with-code](.agents/skills/docs-align-with-code/SKILL.md) | 実装を正としてプロジェクト全体の利用・開発・運用文書を更新する。有用な説明と重要な制約を残し、古い記述・重複・不足を整理する | `$docs-align-with-code`<br>`$docs-align-with-code README.md を現状の実装に合わせて更新して` | 対象のドキュメントと実装を参照できること |

### Codex の雑務用スキル

使う準備の確認や、書類などのファイル整理に使う。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [skills-preflight](.agents/skills/skills-preflight/SKILL.md) | スキルの定義・呼び出し設定・リンク、必要なコマンドや検証環境、更新スキルの静的確認・公開7日待機・任意検証の前提を確認する。利用可否と対処をまとめ、環境は変更しない | `$skills-preflight`<br>`$skills-preflight このプロジェクトで使う準備を確認して` | `bash`。各スキルの実行環境は確認対象 |
| [rename-files-by-content](.agents/skills/rename-files-by-content/SKILL.md) | 指定フォルダ直下の通常ファイルを内容から `YYYY-MM-DD_名前.拡張子` に改名する。隠しファイルと、隠しフォルダを含むサブフォルダ内は対象外。請求書・領収書・契約書などに応じて日付と名称を選び、名称の空白は `-` に置き換える。同名は連番、不明なものは元名を保って記録する | `$rename-files-by-content /絶対パス/対象フォルダ`<br>`$rename-files-by-content /絶対パス/対象フォルダ 候補だけ見せて` | `bash`、Python 3.9 以降、対象の読み書き・ハードリンク作成、形式に合う読取・必要に応じた表示や OCR の手段 |

## 実行結果の保存先

レポートなどを保存するスキルは、このリポジトリ直下の `artifacts/<スキル名>/` を使う（`.gitignore` 済み）。他のフォルダから使ったときも同じ場所に保存される。対象プロジェクトを編集するスキルは、依頼されたプロジェクトに変更を加える。

## スキルの追加・変更

配置・命名・description・呼び出し設定・変更時の確認は [AGENTS.md](AGENTS.md) にまとめている。スキルの追加や改名時は、この README の一覧・呼び出し例も更新する。検証は次を実行し、スクリプトを変更した場合は構文と変更した動作も確認する。

```bash
scripts/check-descriptions.sh
git diff --check
```

追加・改名・削除後は、[リンク手順](#1-ユーザー用ディレクトリへリンクする) に沿ってユーザー用リンクも更新する。

## ライセンス

[MIT License](LICENSE)
