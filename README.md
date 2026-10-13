# agent-skills

普段の仕事で使う汎用的な Claude Code スキル集。このフォルダを Claude Code で開くと使える。

## スキル一覧

`/スキル名` で呼び出すか、「使い方の例」のように話しかける。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [gh-my-work](.claude/skills/gh-my-work/SKILL.md) | レビュー依頼されている PR、直近のメンションで未返信のもの、自分にアサインされている open な Issue / PR を組織ごとの表で一覧化する | `/gh-my-work`<br>「自分の担当を見せて」<br>「返信が必要なメンションとレビュー依頼だけ」 | `gh` にログイン済み |
| [gh-issue-overview](.claude/skills/gh-issue-overview/SKILL.md) | Issue を調べ、「なにをどうするか」がひと目でわかる実装計画の概要（前提・5W1H・全体像の図・進め方）を組み込みブラウザに表示する（`artifacts/gh-issue-overview/` に保存）。細かい実装には触れない | `/gh-issue-overview <Issue の URL>`<br>「この Issue の実装計画を立てて <URL>」<br>「<URL> の概要を 5W1H で整理して」 | `gh` にログイン済み、`python3` |
| [repo-security-audit](.claude/skills/repo-security-audit/SKILL.md) | Cloudflare の security-audit スキル（Full audit）で、指定したリポジトリ（省略時は今のフォルダの下のリポジトリすべて）を 1 つずつ包括的にセキュリティ監査する。ソースの変更や本番・外部サービスへのアクセスはせず、確定した問題・未検証事項・未調査領域を日本語で報告する（`artifacts/repo-security-audit/` に保存） | `/repo-security-audit asked_backend asked_frontend`<br>`/repo-security-audit --profile quick`<br>「このワークスペースのリポジトリをセキュリティ監査して」 | [security-audit](https://github.com/cloudflare/security-audit-skill) スキルを導入済み（`npx skills add cloudflare/security-audit-skill`）、`node`、`jq` |

## 実行結果の保存先

レポートなどスキルが作るファイルは、このリポジトリ直下の `artifacts/<スキル名>/` に保存される（`.gitignore` 済み）。他のフォルダから使ったときも同じ場所に保存される。

## 他のフォルダでも使う

`~/.claude/skills/` にシンボリックリンクを張る。

```bash
ln -sfn "$PWD/.claude/skills/<スキル名>" ~/.claude/skills/<スキル名>
```
