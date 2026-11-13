# agent-skills

Claude Code で開発・整備し、Codex で依存の更新と監査をするための汎用スキル集。\
開発以外の作業に使うスキルも置いている。\
特定のプロジェクトに依存しない。

| | Claude Code | Codex |
| --- | --- | --- |
| 役割 | 開発する（設計・実装・テスト・レビュー・PR）、整備する（設計への整合・構造・テスト・宣言順・文書） | 依存を更新する、セキュリティ監査の所見を Issue にする |
| 使い方 | 条件に当たると Claude が自分の判断で使うスキルが中心 | `$スキル名` で指定したときだけ使う |

Claude Code で機能を作り、余裕のあるときにリファクタリング用スキル（codebase-cleanup-workflow）でコードベースを整え、また次の開発に進む。\
Claude は作業の一部を Haiku 5.5・Opus 5.5・Fable 5.2 のサブエージェントや Codex CLI（GPT-6 Astra・GPT-6.1 Sol）に任せ、指示・採否の判断・反映を受け持つ。

## はじめに

1. リポジトリ直下でリンクする。\
   `--claude` / `--codex` で片方だけにできる。\
   スキルの追加・改名・削除のあとも再実行する。

   ```bash
   scripts/link-skills.sh
   ```

   | エージェント | 配置 | リンク先 | 呼び出し方 |
   | --- | --- | --- | --- |
   | Claude Code | `.claude/skills/`、`.claude/agents/` | `~/.claude/skills/`、`~/.claude/agents/`（`CLAUDE_CONFIG_DIR` があればその配下） | `/スキル名` |
   | Codex | `.agents/skills/` | `~/.agents/skills/` | `$スキル名` |

   - 既存の同名ファイルや別の場所へのリンクは上書きしない。\
     このリポジトリを指す切れたリンクは、張り直すか取り除く。
   - git worktree からは実行できない。\
     メインの checkout で実行する。
   - 反映されなければ、新しいセッションを始めるか Codex を再起動する。

2. [skills-preflight](.claude/skills/skills-preflight/SKILL.md)（Claude Code）・[`$skills-preflight`](.agents/skills/skills-preflight/SKILL.md)（Codex）で、必要なコマンド・ログイン・リンクを確かめる。\
   Claude Code では、足りないコマンドとリンクを了承を得てから入れる（ログインはユーザーが行う）。\
   Codex はスキルの定義と Cloudflare の `security-audit` の配置も確かめ、環境は変えない。\
   主な前提は次のとおり（細かい条件は各 SKILL.md にある）。

   | 前提 | 使うスキル |
   | --- | --- |
   | `perl` | design-cross-review・implementation-cross-review・haiku-implementation・gh-issue-autofix・codebase-cleanup-workflow |
   | `git` 2.36 以降 | gh-issue-autofix（Auto-fix で push するとき） |
   | `jq` | haiku-implementation・gh-todo・gh-issue-autofix、クロスレビューの Codex の担当 |
   | `codex` のログイン | クロスレビューの Codex の担当（Astra。使えないときは Sol） |
   | メインが auto モード | haiku-implementation・gh-issue-autofix、codebase-cleanup-workflow（ないときは Haiku に実装を任せない） |
   | `gh` のログイン | gh-todo・gh-issue-autofix・security-audit-to-issues、haiku-check で CI のログを見るとき |
   | Claude デスクトップアプリ | session-status-emoji |
   | 組み込みブラウザか Claude in Chrome | browser-readonly-research |
   | 組み込みブラウザ | gh-issue-autofix（ないときは動作確認を未検証にする） |
   | デスクトップアプリが開いていて PC が起きている（専用の PC を勧める） | スケジュールに登録するスキル |
   | Python 3.9 以降 | Codex の minor-version-upgrade・rename-files-by-content |
   | `node`・Cloudflare の `security-audit`・サブエージェント | security-audit-to-issues |
   | 対象が git リポジトリで、未コミットの変更がない | codebase-cleanup-workflow |

3. 下の一覧から選ぶ。\
   名前のリンク先に、手順とオプションがある。

## Claude Code 用スキル一覧

自動で使われるスキルも、`/スキル名` や話しかけて使える。

### 自動で使われるスキル

条件に当たると、Claude が頼まれなくても使う。\
作業の流れ（セッション開始 → 設計 → 実装 → 確認 → レビュー → 報告）の順に並べている。

| スキル | できること | 使う場面 |
| --- | --- | --- |
| [session-status-emoji](.claude/skills/session-status-emoji/SKILL.md) | セッション名に作業の段階の絵文字を付ける | デスクトップアプリの全セッション |
| [design-cross-review](.claude/skills/design-cross-review/SKILL.md) | 設計を Astra と Fable にレビューさせる（直したあとは Astra が確認） | 設計・実装計画を示す前 |
| [haiku-implementation](.claude/skills/haiku-implementation/SKILL.md) | 実装を Haiku 5.5 に任せ、手分けして進める | 指示書に書けて確かめられる実装 |
| [haiku-check](.claude/skills/haiku-check/SKILL.md) | テスト・lint・CI ログの確認を Haiku 5.5 に任せる | 状態を変えない確認 |
| [implementation-cross-review](.claude/skills/implementation-cross-review/SKILL.md) | 差分を Astra と Fable にレビューさせて直す（直したあとは Astra が確認） | 完了報告・コミット・PR の前 |
| [japanese-report](.claude/skills/japanese-report/SKILL.md) | 報告を自然な日本語で書く | 結果を報告する前 |

### リファクタリング用スキル

`/スキル名` で指定したときだけ使う。\
既存の振る舞いを変えずに、コード・テスト・文書を整える。\
codebase-cleanup-workflow は残りの 5 本を上から順に使い、工程ごとに Astra と Fable のレビューを挟む。

| スキル | できること |
| --- | --- |
| [codebase-cleanup-workflow](.claude/skills/codebase-cleanup-workflow/SKILL.md) | 設計整合から文書同期までの整備を一巡し、工程ごとに Astra と Fable のレビューを受けて作業ブランチにコミットする |
| [design-alignment-refactor](.claude/skills/design-alignment-refactor/SKILL.md) | 設計方針から外れた責務分担や依存関係を直す |
| [code-structure-refactor](.claude/skills/code-structure-refactor/SKILL.md) | 責務の混在や重複を、分割・共通化で直す |
| [test-suite-refactor](.claude/skills/test-suite-refactor/SKILL.md) | 検出力を保ったまま、テストの重複を整理する |
| [code-order-refactor](.claude/skills/code-order-refactor/SKILL.md) | メソッドや関数を読みやすい順に並べ替える |
| [docs-align-with-code](.claude/skills/docs-align-with-code/SKILL.md) | 実装に合わせて文書を更新する |

### 指定して使うスキル

`/スキル名` で指定したときだけ使う。

| スキル | できること |
| --- | --- |
| [whats-next](.claude/skills/whats-next/SKILL.md) | 進捗と次のアクションを 1 つ示し、承認後に進める |
| [gh-todo](.claude/skills/gh-todo/SKILL.md) | レビュー依頼・メンション・自分の Issue / PR を一覧にする |
| [browser-readonly-research](.claude/skills/browser-readonly-research/SKILL.md) | Web ページを読むだけで調べてまとめる |

### スケジュールに登録するスキル

Claude デスクトップアプリのスケジュールタスクに登録し、`/スキル名` で定期実行する。\
登録のしかたと試運転は SKILL.md にある。

| スキル | できること |
| --- | --- |
| [gh-issue-autofix](.claude/skills/gh-issue-autofix/SKILL.md) | `agent:autofix` ラベルの Issue を 1 件、確認なしで対応して同じラベルのドラフト PR にし、止めたら Issue に理由を書いて、Issue が更新されたら続きから再開する。受け入れ条件を満たして作った PR の指摘・CI の失敗・競合には Auto-fix で対応する。リポジトリの親ディレクトリに登録すると、配下から Issue か PR を選んでそのセッションで対応し、PR の指摘・CI の失敗・競合は定期実行で拾う |

## Codex 用スキル一覧

すべて `$スキル名` で指定したときだけ使う。

| スキル | できること |
| --- | --- |
| [`$minor-version-upgrade`](.agents/skills/minor-version-upgrade/SKILL.md) | ランタイムと依存を、互換性を保つ範囲で更新する |
| [`$security-audit-to-issues`](.agents/skills/security-audit-to-issues/SKILL.md) | 自律監査で確定所見の修正 Issue と全判定の集約 Issue を作成・更新し、自動修正できる項目にラベルを付ける |

## 開発以外のスキル

開発の流れとは別に、普段の作業で使う。

| スキル | エージェント | できること |
| --- | --- | --- |
| [`$rename-files-by-content`](.agents/skills/rename-files-by-content/SKILL.md) | Codex | ファイルを内容から `YYYY-MM-DD_名前` に改名する |

## 実行結果とスキルの追加・変更

- スキルの作業用ファイルは、このリポジトリの `artifacts/<スキル名>/`（gitignore 済み）に置く。
- `security-audit-to-issues` の監査成果物は、Cloudflare の `security-audit` と同じ `~/security-audit-skill/<repo-name>/run-<N>/` に保存される。
- 作り方のルールは [AGENTS.md](AGENTS.md) にある。\
  変更したら `scripts/check-descriptions.sh` と `git diff --check` を実行し、追加・改名・削除のあとは `scripts/link-skills.sh` を実行する。

## ライセンス

[MIT License](LICENSE)
