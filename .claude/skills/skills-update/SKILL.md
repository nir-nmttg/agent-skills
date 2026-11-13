---
name: skills-update
description: agent-skills を git pull で最新にし、Claude Code・Codex へリンクし直して、skills-preflight の確認結果を表示する。
disable-model-invocation: true
allowed-tools: Bash(bash *skills-update/scripts/update.sh*)
---

# スキルの更新

## 実行結果

!`bash "${CLAUDE_SKILL_DIR}/scripts/update.sh" 2>&1`

## 手順

1. 上の「実行結果」に最後の節の「## 確認結果」の見出しがない（空か、スクリプトが最後まで動かなかった）ときだけ、Bash で `bash "${CLAUDE_SKILL_DIR}/scripts/update.sh"` を実行して取り直す。取り込みやリンクの失敗が書かれているときは取り直さない。
2. 実行結果を**そのまま**ユーザーに表示する（ユーザーには実行結果が見えていないため、省略せず出力する）。前置きは書かず、実行結果から始める。
3. 取り込みやリンクを飛ばした・失敗したときは、実行結果に書かれた理由を 1 行で伝える。ブランチの切り替え・stash・コミット・reset などで、自分から直さない。
4. Claude Code の確認結果に ❌ や「Claude が実行できるコマンド」があっても、ここでは実行しない。`/skills-preflight` で確かめて入れられると 1 行で案内する。
5. ほかには何も足さずに終える。
