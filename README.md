# agent-skills

普段の仕事で使う汎用的な Claude Code スキル集。このフォルダを Claude Code で開くと使える。

## スキル一覧

`/スキル名` で呼び出すか、「使い方の例」のように話しかける。

gh-my-work・gh-issue-overview・repo-security-audit は `/スキル名` でしか動かない（話しかけても、Claude が自分の判断で使うこともない）。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [gh-my-work](.claude/skills/gh-my-work/SKILL.md) | レビュー依頼されている PR、直近のメンションで未返信のもの、自分にアサインされている open な Issue / PR を組織ごとの表で一覧化する | `/gh-my-work`<br>`/gh-my-work レビュー依頼とメンションだけ` | `gh` にログイン済み |
| [gh-issue-overview](.claude/skills/gh-issue-overview/SKILL.md) | Issue を調べ、「なにをどうするか」がひと目でわかる実装計画の概要（前提・5W1H・全体像の図・進め方）を組み込みブラウザに表示する（`artifacts/gh-issue-overview/` に保存）。細かい実装には触れない | `/gh-issue-overview <Issue の URL>`<br>`/gh-issue-overview <Issue の URL> バックエンドだけ` | `gh` にログイン済み、`python3` |
| [repo-security-audit](.claude/skills/repo-security-audit/SKILL.md) | Cloudflare の security-audit スキル（Full audit）で、指定したリポジトリ（省略時は今のフォルダの下のリポジトリすべて）を 1 つずつ包括的にセキュリティ監査する。ソースの変更や本番・外部サービスへのアクセスはせず、確定した問題・未検証事項・未調査領域を日本語で報告する（`artifacts/repo-security-audit/` に保存） | `/repo-security-audit`<br>`/repo-security-audit asked_backend asked_frontend`<br>`/repo-security-audit --profile quick` | [security-audit](https://github.com/cloudflare/security-audit-skill) スキルを導入済み（`npx skills add cloudflare/security-audit-skill`）、`node`、`jq` |
| [codex-design-review](.claude/skills/codex-design-review/SKILL.md) | Claude が考えた設計を Codex CLI の GPT-6.1 Sol にセカンドオピニオンとしてレビューさせる。推論レベルは今の Claude と同じ（high なら high）、`--fast` で Fast モード。Codex は読み取り専用で既存コードと照らし合わせ、Claude が指摘ごとに採用・不採用を判断して設計の修正案を出す（`artifacts/codex-design-review/` に保存）。頼まなくても、3 ファイル以上・新しい機能や API・複数案から選んだ設計や、DB・公開 API・認証・課金などに触れる設計は、Claude が提示前に積極的にレビューさせる（迷ったら使う。1〜2 ファイルの局所的な変更は除く） | `/codex-design-review`<br>`/codex-design-review --fast docs/design.md`<br>「この設計を Codex にレビューしてもらって」 | `codex` にログイン済み、`jq` |
| [codex-impl-review](.claude/skills/codex-impl-review/SKILL.md) | Claude が実装した変更（git の差分）を Codex CLI の GPT-6.1 Sol にコードレビューさせる。推論レベルは今の Claude と同じ（high なら high）、`--fast` で Fast モード。範囲は既定ブランチからの変更（未コミットを含む）が既定で、`--base` / `--commit` / `--uncommitted` で選べる。Codex は読み取り専用で差分と周辺コードを読み、Claude が指摘ごとに採用・不採用を判断し、自分が実装した変更なら採用した指摘を直す（`artifacts/codex-impl-review/` に保存）。頼まなくても、数十行以上のロジック変更や、DB・公開 API・認証・課金などに触れる変更は、Claude が完了報告やコミットの前に積極的にレビューさせる（迷ったら使う。数行の変更やドキュメントだけの変更は除く） | `/codex-impl-review`<br>`/codex-impl-review --fast --uncommitted`<br>「実装を Codex にレビューしてもらって」 | `codex` にログイン済み、`jq`、対象が git リポジトリ |
| [codex-impl](.claude/skills/codex-impl/SKILL.md) | 実装を Codex CLI の GPT-6 Luna（推論レベル max・Fast モード固定）に任せ、Claude は分割・指示書づくり・レビューだけを行って Claude のトークンを節約する。ほぼ無料の Luna を活かすため、実装を独立した小タスクに分けて複数の Luna を git worktree で並行して動かし、その間 Claude は Luna に向かない部分を作業フォルダで進める。Codex はサンドボックス（ネットワークなし）で実装し、Claude が差分をレビューして作業フォルダに 3-way マージで反映、テストを実行し、小さな問題は自分で直し、大きな問題は Codex に差し戻す。コミットはしない（`artifacts/codex-impl/` に保存）。頼まなくても、要件と完了の条件がはっきりした部分（既存パターンに沿った機能追加、テスト追加など）は、Claude が積極的に任せる（迷ったら任せる） | `/codex-impl CSV エクスポートを追加して`<br>「この Issue の実装を Luna に並列で任せて」<br>「トークン節約で Codex に実装させてレビューして」 | `codex` にログイン済み、`jq`、対象が git リポジトリ |

## 実行結果の保存先

レポートなどスキルが作るファイルは、このリポジトリ直下の `artifacts/<スキル名>/` に保存される（`.gitignore` 済み）。他のフォルダから使ったときも同じ場所に保存される。

## 他のフォルダでも使う

リポジトリ直下で次を実行すると、すべてのスキルが `~/.claude/skills/` にシンボリックリンクされ、どのフォルダで Claude Code を開いても使える。

```bash
scripts/link-skills.sh
```

- スキルを追加・削除したら、もう一度実行する（新しいスキルはリンクされ、削除したスキルの切れたリンクは消える）
- 同名のスキルが別の場所にあるときは上書きせず、警告だけ出す
