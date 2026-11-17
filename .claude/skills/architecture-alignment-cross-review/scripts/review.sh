#!/usr/bin/env bash
# prepare.sh で作った prompt.md を Codex CLI の GPT-6.2 Sol に読み取り専用でレビューさせ、review.md に保存する。
# Codex の呼び出しは implementation-cross-review の review.sh に任せる。
#
# 使い方: review.sh --effort <low|medium|high|xhigh|max> <実行フォルダ>
#   --effort  Codex の推論レベル。Claude の推論レベルをそのまま渡す（省略時は ${CLAUDE_EFFORT}、それもなければ high）
set -euo pipefail

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

effort="" run_dir=""
while (($#)); do
  case $1 in
    --effort) effort=${2:-}; shift 2 || usage ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../implementation-cross-review/scripts/review.sh
[[ -f $base ]] || { echo "エラー: implementation-cross-review スキルが見つかりません（${base}）" >&2; exit 1; }

IMPLEMENTATION_CROSS_REVIEW_TITLE="Codex の設計適合レビュー" \
  exec bash "$base" --model gpt-6.2-sol ${effort:+--effort "$effort"} "$run_dir"
