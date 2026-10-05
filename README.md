# agent-skills

普段の仕事で使う汎用的な Claude Code スキル集。このフォルダを Claude Code で開くと使える。

## スキル一覧

`/スキル名` で呼び出すか、「使い方の例」のように話しかける。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [gh-my-work](.claude/skills/gh-my-work/SKILL.md) | 自分にアサインされている open な Issue / PR を組織ごとの表で一覧化する | `/gh-my-work`<br>「自分の担当を見せて」<br>「achromono の PR だけ」 | `gh` にログイン済み |
| [gh-issue-plan](.claude/skills/gh-issue-plan/SKILL.md) | Issue・関連 PR・コードを調べ、前提知識と 5W1H を押さえた実装計画を Mermaid 図入りでまとめて組み込みブラウザに表示する（`~/issue-plans/` に保存） | `/gh-issue-plan <Issue の URL>`<br>「この Issue の実装計画を立てて <URL>」<br>「<URL> を 5W1H で整理して」 | `gh` にログイン済み、`python3` |

## 他のフォルダでも使う

`~/.claude/skills/` にシンボリックリンクを張る。

```bash
ln -sfn "$PWD/.claude/skills/<スキル名>" ~/.claude/skills/<スキル名>
```
