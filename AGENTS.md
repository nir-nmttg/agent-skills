# agent-skills

Claude Code・Codex 向けの汎用スキルを管理する。特定プロジェクトのコードに依存するスキルは置かない。両エージェントの作成・変更ルールはこのファイルに集約する。

## 配置と呼び出し設定

| 対象 | 配置 | 明示指定専用の設定 | 呼び出し例 |
| --- | --- | --- | --- |
| Claude Code | `.claude/skills/<skill-name>/SKILL.md` | frontmatter の `disable-model-invocation: true` | `/skill-name` |
| Codex | `.agents/skills/<skill-name>/SKILL.md` | `agents/openai.yaml` の `policy.allow_implicit_invocation: false` | `$skill-name` |

- 名前は kebab-case にし、フォルダ名と frontmatter の `name` を一致させる。
- 本文・description・ユーザーへの報告は日本語で簡潔にする。識別子・コマンドなどは原文を保つ。
- 既存の呼び出し方針を維持する。新規スキルは通常の自動選択を基本とし、ユーザーが指定した場合は明示指定専用にする。
- Codex の frontmatter は `name`・`description` を基本とし、UI 表示・呼び出し設定は `agents/openai.yaml` に書く。Claude 専用の設定・変数を持ち込まない。

## description と本文

- 自動選択されるスキルは 200 文字以内で、何をするか・いつ使うかを書く。使う手段やモデルが重要なら含め、想定フレーズは 2 つまでにする。
- 明示指定専用のスキルは 120 文字以内で機能を説明する。自動選択用の想定フレーズや発動条件、設定と重複する「明示指定したときだけ使う」は書かない。
- 手順・選択肢・オプション・細かい発動条件は本文へ置く。確認してから使うスキルは、その条件と確認方法も本文に書く。

## スクリプトと実行結果

- 繰り返し使う定型処理は各スキルの `scripts/` にまとめる。短い指示だけで完結するスキルに不要なスクリプトや補助ファイルを増やさない。
- Claude 用のスクリプトは `${CLAUDE_SKILL_DIR}/scripts/...` で参照し、実行に必要なコマンドだけを `allowed-tools` に指定する。Codex 用はスキルからの相対パスで参照する。
- レポートなどの実行結果を保存する場合は、このリポジトリの `artifacts/<skill-name>/`（gitignore 済み）へ置く。対象プロジェクトを編集するスキルは依頼された対象へ変更する。
- 保存先を求めるスクリプトは自身のパスから `cd -P` でリポジトリを特定し、ユーザー用ディレクトリのシンボリックリンク経由でも同じ場所を使う。

## 変更時の確認

- 追加・改名・機能や呼び出し方の変更時は README.md の該当するエージェントの一覧を更新する。既存の表に合わせ、自動で使う条件・確認される条件は「できること」と分け、明示指定専用の例は `/skill-name`・`$skill-name` で示す。Claude の種類別一覧も同期する。
- `scripts/check-descriptions.sh` と `git diff --check` を実行する。スクリプトを変えた場合は構文と変更した動作も確認する。
- 追加・改名・削除後のリンク更新は `scripts/link-skills.sh` で両方、`--claude` / `--codex` で片方を実行する。通常の本文修正はリンク先にも反映される。
- リンクコマンドの、別の場所の同名ファイル・有効なリンクを上書きしない動作と、worktree からの実行を断る動作を維持する。
