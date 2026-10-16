---
name: setup-check
description: このリポジトリのスキルを使うのに必要なもの（git・jq・codex・claude・gh・python3・curl・node のコマンド、Codex・Claude・gh のログイン、Cloudflare の security-audit スキル）がそろっているかを確認し、スキルごとに使える / 使えないをまとめる。足りないものはインストール・ログインの方法を案内する。`/setup-check` で明示的に呼び出したときだけ動く。
disable-model-invocation: true
allowed-tools: Bash(bash *setup-check/scripts/check.sh*)
---

# スキルを使う準備の確認

## 確認結果

!`bash "${CLAUDE_SKILL_DIR}/scripts/check.sh" 2>&1`

## 手順

1. 上の「確認結果」が空、またはエラーの場合は、Bash で `bash "${CLAUDE_SKILL_DIR}/scripts/check.sh"` を実行して取り直す。
2. 確認結果を**そのまま**ユーザーに表示する（ユーザーには確認結果が見えていないため、省略せず出力する）。表・対処方法の文言やコマンドは変えない。
3. ❌ があれば、最後に「対処方法のコマンドを実行してから、もう一度 `/setup-check` で確認してください」と 1 行で促す。すべて ✅（⚠️ だけ）なら何も足さない。
4. インストールやログインは自分では実行しない（ユーザーの環境を変えるため、案内だけにする）。ユーザーに頼まれたときだけ実行する。
5. 前置きや手順の説明は書かず、確認結果から始める。
