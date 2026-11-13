# agent-skills

Claude Code と Codex 向けの、特定のプロジェクトに依存しない汎用スキル集。\
Claude Code では開発と整備（リファクタリング）に、Codex では依存の更新とセキュリティ監査に使い、開発以外の作業に使うスキルもある。\
Claude は作業の一部を Haiku 5.5・Fable 5.2（利用枠が足りなければ Opus 5.5）のサブエージェントや Codex CLI（GPT-6 Astra、使えなければ GPT-6.1 Sol）に任せ、指示・採否・反映を受け持つ。

## はじめに

1. メインの checkout の直下でリンクする（git worktree からは実行できない）。\
   Claude Code は `~/.claude/skills/`・`~/.claude/agents/`（`CLAUDE_CONFIG_DIR` があればその配下）、Codex は `~/.agents/skills/` にリンクされ、`--claude` / `--codex` で片方だけにできる。\
   既存の同名ファイルや、別の場所への有効なリンクは上書きしない。\
   スキルの追加・改名・削除のあとも再実行し、反映されなければ新しいセッションを始めるか Codex を再起動する。

   ```bash
   scripts/link-skills.sh
   ```

2. [skills-preflight](.claude/skills/skills-preflight/SKILL.md)（Claude Code）・[`$skills-preflight`](.agents/skills/skills-preflight/SKILL.md)（Codex）で、必要なコマンド・ログイン・リンクを確かめる（Claude Code では足りないコマンドとリンクを了承を得てから入れる）。\
   主な前提は次のとおり（細かい条件は各 SKILL.md にある）。

   | 前提 | 使うスキル |
   | --- | --- |
   | `perl` | design-cross-review・implementation-cross-review・haiku-implementation・gh-issue-autofix・codebase-cleanup-workflow |
   | `jq` | haiku-implementation・gh-issue-autofix、クロスレビューの Codex の担当 |
   | `codex` のログイン | クロスレビューの Codex の担当 |
   | メインが auto モード | haiku-implementation、codebase-cleanup-workflow（ないときは Haiku に実装を任せない） |
   | `gh` のログイン | gh-todo・gh-issue-autofix・security-audit-to-issues、haiku-check で CI のログを見るとき |
   | Claude デスクトップアプリ | session-status-emoji |
   | 組み込みブラウザか Claude in Chrome | browser-readonly-research |
   | 組み込みブラウザ | gh-issue-autofix（ないときは動作確認を未検証にする） |
   | Python 3.9 以降 | Codex の minor-version-upgrade・rename-files-by-content |
   | `node`・Cloudflare の `security-audit`・サブエージェント | security-audit-to-issues |
   | 対象が git リポジトリで、未コミットの変更がない | codebase-cleanup-workflow |

## Claude Code 用スキル一覧

`/スキル名` で指定して使う。\
自動で使われるスキルも、指定や話しかけで使える。

### 自動で使われるスキル

条件に当たると、頼まれなくても使う。

| スキル | できること | 使う場面 |
| --- | --- | --- |
| [session-status-emoji](.claude/skills/session-status-emoji/SKILL.md) | セッション名に作業の段階の絵文字を付ける | デスクトップアプリの全セッション |
| [design-cross-review](.claude/skills/design-cross-review/SKILL.md) | 設計を Astra と Fable にレビューさせる | 設計・実装計画を示す前 |
| [haiku-implementation](.claude/skills/haiku-implementation/SKILL.md) | 実装を Haiku 5.5 に任せ、手分けして進める | 指示書に書けて確かめられる実装 |
| [haiku-check](.claude/skills/haiku-check/SKILL.md) | テスト・lint・CI ログの確認を Haiku 5.5 に任せる | 状態を変えない確認 |
| [implementation-cross-review](.claude/skills/implementation-cross-review/SKILL.md) | 差分を Astra と Fable にレビューさせて直す | 完了報告・コミット・PR の前 |
| [japanese-report](.claude/skills/japanese-report/SKILL.md) | 報告を自然な日本語で書く | 結果を報告する前 |

### リファクタリング用スキル

指定したときだけ使い、振る舞いを変えずにコード・テスト・文書を整える。

| スキル | できること |
| --- | --- |
| [codebase-cleanup-workflow](.claude/skills/codebase-cleanup-workflow/SKILL.md) | 下の 5 本を順に使い、工程ごとに Haiku の確認と Astra・Fable のレビューを挟んで作業ブランチにコミットする |
| [design-alignment-refactor](.claude/skills/design-alignment-refactor/SKILL.md) | 設計方針から外れた責務分担や依存関係を直す |
| [code-structure-refactor](.claude/skills/code-structure-refactor/SKILL.md) | 責務の混在や重複を、分割・共通化で直す |
| [test-suite-refactor](.claude/skills/test-suite-refactor/SKILL.md) | 検出力を保ったまま、テストの重複を整理する |
| [code-order-refactor](.claude/skills/code-order-refactor/SKILL.md) | メソッドや関数を読みやすい順に並べ替える |
| [docs-align-with-code](.claude/skills/docs-align-with-code/SKILL.md) | 実装に合わせて文書を更新する |

### 指定して使うスキル

次の作業の提案、GitHub の Issue / PR の対応、Web での調査など、必要なときに呼ぶ。

| スキル | できること |
| --- | --- |
| [whats-next](.claude/skills/whats-next/SKILL.md) | 進捗と次のアクションを 1 つ示し、承認後に進める |
| [gh-todo](.claude/skills/gh-todo/SKILL.md) | レビュー依頼・メンション・自分の Issue / PR を一覧にする |
| [browser-readonly-research](.claude/skills/browser-readonly-research/SKILL.md) | Web ページを読むだけで調べてまとめる |
| [gh-issue-autofix](.claude/skills/gh-issue-autofix/SKILL.md) | `agent:autofix` ラベルの Issue を 1 件対応し、同じラベルのドラフト PR にする |

## Codex 用スキル一覧

すべて `$スキル名` で指定したときだけ使う。

| スキル | できること |
| --- | --- |
| [`$minor-version-upgrade`](.agents/skills/minor-version-upgrade/SKILL.md) | ランタイムと依存を、互換性を保つ範囲で更新する |
| [`$security-audit-to-issues`](.agents/skills/security-audit-to-issues/SKILL.md) | 自律監査で確定所見の修正 Issue と全判定の集約 Issue を作成・更新し、自動修正できる項目にラベルを付ける |

## 開発以外のスキル

| スキル | エージェント | できること |
| --- | --- | --- |
| [`$rename-files-by-content`](.agents/skills/rename-files-by-content/SKILL.md) | Codex | ファイルを内容から `YYYY-MM-DD_名前` に改名する |

## スキルの追加・変更

作り方と変更時の確認は [AGENTS.md](AGENTS.md) にある。\
スキルの作業用ファイルは、このリポジトリの `artifacts/<スキル名>/`（gitignore 済み）に置く（security-audit-to-issues の監査結果は `~/security-audit-skill/` 配下）。

## ライセンス

[MIT License](LICENSE)
