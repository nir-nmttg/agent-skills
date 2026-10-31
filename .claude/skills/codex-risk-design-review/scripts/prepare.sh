#!/usr/bin/env bash
# Astra に読ませる prompt.md を作る。処理は codex-design-review の prepare.sh に任せ、指示書と入力を差し替える。
#
# 使い方: prepare.sh [--cd <dir>] <実行フォルダ>
#   引数の意味は codex-design-review の prepare.sh と同じ
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../codex-design-review/scripts/prepare.sh
[[ -f $base ]] || { echo "エラー: codex-design-review スキルが見つかりません（${base}）" >&2; exit 1; }

CODEX_DESIGN_REVIEW_PROMPT=$here/../assets/review-prompt.md \
CODEX_DESIGN_REVIEW_INPUT=design \
  exec bash "$base" "$@"
