#!/usr/bin/env bash
# prepare.sh で作った prompt.md を Codex CLI（既定は GPT-6 Astra）に読み取り専用でレビューさせ、review.md に保存する。
# Codex の呼び出しは implementation-cross-review の review.sh に任せ、見出しと既定のモデル（Astra）だけを差し替える。
#
# 使い方: review.sh [--model <id>] --effort <low|medium|high|xhigh|max> <実行フォルダ>
#   引数の意味は implementation-cross-review の review.sh と同じ（--model の既定だけ gpt-6-astra）
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../implementation-cross-review/scripts/review.sh
[[ -f $base ]] || { echo "エラー: implementation-cross-review スキルが見つかりません（${base}）" >&2; exit 1; }

IMPLEMENTATION_CROSS_REVIEW_TITLE="Codex の設計レビュー" \
  exec bash "$base" --model gpt-6-astra "$@" # 呼び出し側の --model があれば、後に読む方が勝つ
