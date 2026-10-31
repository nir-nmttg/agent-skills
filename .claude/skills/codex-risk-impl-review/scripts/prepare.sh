#!/usr/bin/env bash
# Astra に読ませる prompt.md を作る。処理は codex-impl-review の prepare.sh に任せ、指示書と入力だけを差し替える。
#
# 使い方: prepare.sh [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] <実行フォルダ>
#   引数の意味は codex-impl-review の prepare.sh と同じ。入力は <実行フォルダ>/context.md（実装の説明）
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../codex-impl-review/scripts/prepare.sh
[[ -f $base ]] || { echo "エラー: codex-impl-review スキルが見つかりません（${base}）" >&2; exit 1; }

CODEX_IMPL_REVIEW_PROMPT=$here/../assets/review-prompt.md \
CODEX_IMPL_REVIEW_INPUT=context \
  exec bash "$base" "$@"
