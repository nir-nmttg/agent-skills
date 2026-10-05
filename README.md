# agent-skills

普段の仕事で使う汎用的な Claude Code スキル集。このフォルダを Claude Code で開くと使える。

## スキル一覧

`/スキル名` で呼び出すか、「使い方の例」のように話しかける。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [gh-my-work](.claude/skills/gh-my-work/SKILL.md) | 自分にアサインされている open な Issue / PR を組織ごとの表で一覧化する | `/gh-my-work`<br>「自分の担当を見せて」<br>「achromono の PR だけ」 | `gh` にログイン済み |
| [gh-issue-overview](.claude/skills/gh-issue-overview/SKILL.md) | Issue を調べ、「なにをどうするか」がひと目でわかる実装計画の概要（前提・5W1H・全体像の図・進め方）を組み込みブラウザに表示する（`~/issue-plans/` に保存）。細かい実装には触れない | `/gh-issue-overview <Issue の URL>`<br>「この Issue の実装計画を立てて <URL>」<br>「<URL> の概要を 5W1H で整理して」 | `gh` にログイン済み、`python3` |

## 他のフォルダでも使う

`~/.claude/skills/` にシンボリックリンクを張る。

```bash
ln -sfn "$PWD/.claude/skills/<スキル名>" ~/.claude/skills/<スキル名>
```
