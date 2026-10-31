#!/usr/bin/env bash
# Astra に読ませる prompt.md を作る。処理は design-cross-review の prepare.sh に任せ、指示書と入力を差し替える。
#
# 使い方: prepare.sh [--cd <dir>] <実行フォルダ>
#   引数の意味は design-cross-review の prepare.sh と同じ
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../design-cross-review/scripts/prepare.sh
[[ -f $base ]] || { echo "エラー: design-cross-review スキルが見つかりません（${base}）" >&2; exit 1; }

DESIGN_CROSS_REVIEW_PROMPT=$here/../assets/review-prompt.md \
DESIGN_CROSS_REVIEW_INPUT=design \
  exec bash "$base" "$@"
