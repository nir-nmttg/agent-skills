#!/usr/bin/env bash
# prepare.sh で作った prompt.md を Codex CLI（GPT-6 Astra）に読み取り専用でレビューさせ、review.md に保存する。
# Codex の呼び出しは design-cross-review の review.sh に任せ、モデルと見出しだけを差し替える。
#
# 使い方: review.sh --effort <low|medium|high|xhigh|max> <実行フォルダ>
#   引数の意味は design-cross-review の review.sh と同じ
#
# 環境変数 CODEX_RISK_DESIGN_REVIEW_MODEL でモデルを変えられる（既定: gpt-6-astra）。
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../design-cross-review/scripts/review.sh
[[ -f $base ]] || { echo "エラー: design-cross-review スキルが見つかりません（${base}）" >&2; exit 1; }

DESIGN_CROSS_REVIEW_MODEL=${CODEX_RISK_DESIGN_REVIEW_MODEL:-gpt-6-astra} \
DESIGN_CROSS_REVIEW_TITLE="Codex の設計リスクレビュー" \
  exec bash "$base" "$@"
