# agent-skills

Claude Code で開発し、Codex で整備するための汎用スキル集。特定のプロジェクトに依存しない。

| | Claude Code | Codex |
| --- | --- | --- |
| 役割 | 開発する（設計・実装・テスト・レビュー・PR） | 整備する（設計への整合・構造・テスト・宣言順・文書・依存の更新）と、ファイル整理 |
| 使い方 | 条件に当たると Claude が自分の判断で使うスキルが中心 | `$スキル名` で指定したときだけ使う |

Claude Code で機能を作り、余裕のあるときに Codex でコードベースを整え（`$codebase-cleanup-workflow`）、また Claude Code で次の開発に進む。Claude は作業の一部を Haiku 5.5・Opus 5.5・Fable 5.1 のサブエージェントや Codex CLI（GPT-6 Astra・GPT-6.1 Sol）に任せ、指示・採否の判断・反映を受け持つ。

## はじめに

1. リポジトリ直下でリンクする。`--claude` / `--codex` で片方だけにできる。スキルの追加・改名・削除のあとも再実行する。

   ```bash
   scripts/link-skills.sh
   ```

   | エージェント | 配置 | リンク先 | 呼び出し方 |
   | --- | --- | --- | --- |
   | Claude Code | `.claude/skills/`、`.claude/agents/` | `~/.claude/skills/`、`~/.claude/agents/`（`CLAUDE_CONFIG_DIR` があればその配下） | `/スキル名` |
   | Codex | `.agents/skills/` | `~/.agents/skills/` | `$スキル名` |

   - 既存の同名ファイルや別の場所へのリンクは上書きしない。このリポジトリを指す切れたリンクは、張り直すか取り除く。
   - git worktree からは実行できない。メインの checkout で実行する。
   - 反映されなければ、新しいセッションを始めるか Codex を再起動する。

2. `/skills-preflight`（Claude Code）・`$skills-preflight`（Codex）で、必要なコマンド・ログイン・リンクを確かめる。確認だけで、環境は変えない。

3. 下の一覧から選ぶ。名前のリンク先に手順とオプションがある。

## Claude Code 用スキル一覧

自動で使われるスキルも、`/スキル名` や話しかけて使える。

### 自動で使われるスキル

条件に当たると、Claude が頼まれなくても使う。作業の流れ（セッション開始 → 設計 → 実装 → 確認 → レビュー → 報告）の順に並べている。

| スキル | できること | 自動で使う条件 | 使い方の例 | 前提 |
| --- | --- | --- | --- | --- |
| [session-status-emoji](.claude/skills/session-status-emoji/SKILL.md) | セッション名の先頭に作業の段階の絵文字を付け、並行セッションを見分けやすくする | デスクトップアプリのすべてのセッションの最初のターンから | 「セッション名に状態の絵文字を付けて」 | Claude デスクトップアプリ |
| [design-cross-review](.claude/skills/design-cross-review/SKILL.md) | 設計を Astra と Fable に同じ依頼でレビューさせ、Claude が採否を判断して修正案を出す。壊れると影響の大きい設計は、壊れ方と戻しやすさも見る | 作り方の判断を含む設計・実装計画を、提示・実装する前（迷ったら使う） | `/design-cross-review docs/design.md`<br>「この設計を Codex にレビューしてもらって」 | `perl`、`~/.claude/agents` のリンク、implementation-cross-review スキル。Astra には `codex` のログインと `jq` |
| [haiku-implementation](.claude/skills/haiku-implementation/SKILL.md) | 実装を Haiku 5.5（max）に任せ、Claude は分割・指示・レビュー・反映に集中する。手分けできる部分は worktree で同時に実装する。コミットはしない | 指示書に書けて、テストなどで確かめられる実装に取りかかるとき（迷ったら任せる） | `/haiku-implementation CSV エクスポートを追加して`<br>「Haiku に並列で実装させて」 | メインが auto モード、`jq`、`perl`、git リポジトリ、`~/.claude/agents` と `~/.claude/skills/haiku-implementation` のリンク |
| [haiku-check](.claude/skills/haiku-check/SKILL.md) | テスト・型チェック・lint・ビルド・依存の脆弱性検査・CI の失敗ログなど、出力が長く状態を変えない確認を Haiku 5.5 に任せ、要点と原因だけを受け取る | Claude がこれらの確認を実行するとき（迷ったら任せる。状態を変えるコマンドと本番への接続は除く） | `/haiku-check`<br>「CI が落ちた理由を見て」 | `~/.claude/agents` のリンク（CI のログには `gh` のログイン） |
| [implementation-cross-review](.claude/skills/implementation-cross-review/SKILL.md) | git の差分を Astra と Opus に、要件と差分だけを渡してレビューさせ、Claude が採否を判断して直す。壊れると影響の大きい変更は、壊れ方も見る | 動作が変わりうる変更（プロンプト・設定を含む）の完了報告・コミット・PR の前（迷ったら使う。README など動作を決めない文書だけなら Opus だけ。Haiku に書かせた変更には必ず使う） | `/implementation-cross-review`<br>`/implementation-cross-review --only opus` | `perl`、git リポジトリ、`~/.claude/agents` のリンク。Astra には `codex` のログインと `jq` |
| [japanese-report](.claude/skills/japanese-report/SKILL.md) | 報告を見出しまで自然な日本語で書く。英語の出力も日本語で要約する | 結果を報告する前 | 「日本語で報告して」 | なし |

design-cross-review と implementation-cross-review は推論レベルを今の Claude に揃え、`--only` で担当を選べる（設計は `astra|sol|fable`、実装は `astra|sol|opus`）。Codex の担当が使えないときは、どちらも Sol で代わりに動かす。

### `/スキル名` で指定したときだけ使うスキル

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [whats-next](.claude/skills/whats-next/SKILL.md) | 会話とブランチ・PR の状態から、進捗と次のアクションを 1 つ示し、承認後に進める | `/whats-next` | なし |
| [skills-preflight](.claude/skills/skills-preflight/SKILL.md) | 必要なコマンド・ログイン・リンクを確かめ、スキルごとに使えるかをまとめる | `/skills-preflight` | なし |
| [gh-todo](.claude/skills/gh-todo/SKILL.md) | レビュー依頼・未返信のメンション・自分の Issue / PR を組織ごとの表にする | `/gh-todo` | `gh` のログイン |
| [browser-readonly-research](.claude/skills/browser-readonly-research/SKILL.md) | Web ページを読み取りだけで調べ、要点と出典をまとめる（Chrome は `--chrome` か頼まれたときだけ） | `/browser-readonly-research <URL> 要点をまとめて` | 組み込みブラウザか Claude in Chrome |

whats-next 以外は、調べる先（環境・GitHub・Web）を読むだけで変えない。

## Codex 用スキル一覧

すべて `$スキル名` で指定したときだけ使う。コードを整えるスキル（minor-version-upgrade から docs-align-with-code まで）は既存の振る舞いを保ち、対象を省略するとプロジェクト全体を探す。minor-version-upgrade は互換性を確かめたうえで、必要な移行も行う。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [minor-version-upgrade](.agents/skills/minor-version-upgrade/SKILL.md) | Ruby・Node・Python のランタイムと依存を、互換性を保つ範囲でまとめて更新する。公開から 7 日以上たった版だけを選び、静的ゲートで確かめてから反映する | `$minor-version-upgrade` | `bash`、Python 3.9 以降（ほかの前提は本文） |
| [codebase-cleanup-workflow](.agents/skills/codebase-cleanup-workflow/SKILL.md) | 設計整合 → 責務分割・共通化 → テスト整理 → 宣言順 → 文書同期を一巡する（依存の更新は含めない） | `$codebase-cleanup-workflow 今回は src/billing のみ整備して` | 下の 5 つのスキル |
| [design-alignment-refactor](.agents/skills/design-alignment-refactor/SKILL.md) | プロジェクトの設計方針から外れた責務分担や依存関係を直す | `$design-alignment-refactor` | 関連する検証を実行できること |
| [code-structure-refactor](.agents/skills/code-structure-refactor/SKILL.md) | 責務の混在や重複を、責務分割・共通化で直す | `$code-structure-refactor` | 関連する検証を実行できること |
| [test-suite-refactor](.agents/skills/test-suite-refactor/SKILL.md) | 検出力を保ったまま、重複や実装の細部に頼るテストを整理する | `$test-suite-refactor` | テストの実行環境 |
| [code-order-refactor](.agents/skills/code-order-refactor/SKILL.md) | メソッドや関数を読みやすい順に並べ替える | `$code-order-refactor` | 関連する検証を実行できること |
| [docs-align-with-code](.agents/skills/docs-align-with-code/SKILL.md) | 実装を正として、利用・開発・運用の文書を更新する | `$docs-align-with-code README.md を現状の実装に合わせて更新して` | なし |
| [rename-files-by-content](.agents/skills/rename-files-by-content/SKILL.md) | フォルダ直下のファイルを、内容から `YYYY-MM-DD_名前.拡張子` に改名する | `$rename-files-by-content /絶対パス/フォルダ` | `bash`、Python 3.9 以降 |
| [skills-preflight](.agents/skills/skills-preflight/SKILL.md) | スキルの定義・リンク・必要なコマンドと検証環境を確かめる。環境は変えない | `$skills-preflight` | `bash` |

## 実行結果とスキルの追加・変更

- レポートなどは、このリポジトリの `artifacts/<スキル名>/`（gitignore 済み）に保存される。
- 作り方のルールは [AGENTS.md](AGENTS.md) にある。変更したら `scripts/check-descriptions.sh` と `git diff --check` を実行し、追加・改名・削除のあとは `scripts/link-skills.sh` を実行する。

## ライセンス

[MIT License](LICENSE)
