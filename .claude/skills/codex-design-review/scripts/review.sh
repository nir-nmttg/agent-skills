#!/usr/bin/env bash
# 実行フォルダの design.md を Codex CLI（GPT-6.1 Sol）に読み取り専用でレビューさせ、review.md に保存する。
#
# 使い方: review.sh --effort <low|medium|high|xhigh|max> [--fast] [--cd <dir>] <実行フォルダ>
#   --effort  Codex の推論レベル。Claude の推論レベルをそのまま渡す（省略時は $CLAUDE_EFFORT、それもなければ high）
#   --fast    Fast モード（service_tier=fast）で実行する。速いぶん使用量が増える
#   --cd      Codex が既存コードを確かめるときの作業フォルダ（既定: 今のフォルダ）
#
# 環境変数 CODEX_DESIGN_REVIEW_MODEL でモデルを、CODEX_DESIGN_REVIEW_PROMPT でレビューの指示書を、
# CODEX_DESIGN_REVIEW_TITLE で出力の見出しを変えられる（codex-risk-design-review が使う）。
set -euo pipefail

usage() { sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

effort="" fast="" workdir=$PWD run_dir=""
while (($#)); do
  case $1 in
    --effort) effort=${2:-}; shift 2 || usage ;;
    --fast) fast=1; shift ;;
    --cd) workdir=${2:-}; shift 2 || usage ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

model=${CODEX_DESIGN_REVIEW_MODEL:-gpt-6.1-sol}
prompt_file=${CODEX_DESIGN_REVIEW_PROMPT:-$(dirname "$0")/../assets/review-prompt.md}
title=${CODEX_DESIGN_REVIEW_TITLE:-Codex の設計レビュー}
effort=${effort:-${CLAUDE_EFFORT:-}}
case $effort in
  low | medium | high | xhigh | max) ;;
  "" | auto) echo "注意: Claude の推論レベルがわからないため high で実行します" >&2; effort=high ;;
  *) echo "エラー: 推論レベル '$effort' には対応していません（low / medium / high / xhigh / max）" >&2; exit 1 ;;
esac

command -v codex >/dev/null || { echo "エラー: codex コマンドが見つかりません（brew install --cask codex）" >&2; exit 1; }
[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
[[ -f $run_dir/design.md ]] || { echo "エラー: $run_dir/design.md がありません" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
workdir=$(cd -P "$workdir" && pwd)

args=(
  exec
  --ignore-user-config # 個人設定の MCP サーバーやプラグインを読み込まない
  --sandbox read-only
  --skip-git-repo-check
  --cd "$workdir"
  --model "$model"
  -c "model_reasoning_effort=\"$effort\""
  --json
  --output-last-message "$run_dir/review.md"
)
fast_label=off
[[ -n $fast ]] && { args+=(-c 'service_tier="fast"'); fast_label=on; }

{
  cat "$prompt_file"
  printf '\n\n<design>\n'
  cat "$run_dir/design.md"
  printf '\n</design>\n'
} >"$run_dir/prompt.md"

echo "Codex でレビュー中: model=$model effort=$effort fast=$fast_label cwd=$workdir" >&2
started=$SECONDS
status=0
codex "${args[@]}" - <"$run_dir/prompt.md" >"$run_dir/events.jsonl" 2>"$run_dir/codex.log" || status=$?

if ((status != 0)) || [[ ! -s $run_dir/review.md ]]; then
  echo "エラー: Codex の実行に失敗しました（終了コード $status）" >&2
  jq -r 'select(.type == "error" or .item.type == "error") | .message // .item.message' "$run_dir/events.jsonl" 2>/dev/null | tail -5 >&2 || true
  tail -20 "$run_dir/codex.log" >&2
  exit 1
fi

# Codex が警告として返したエラー（未対応の service tier など）を表示する
jq -r 'select(.item.type == "error") | "警告: " + .item.message' "$run_dir/events.jsonl" >&2 || true

thread_id=$(jq -r 'select(.type == "thread.started") | .thread_id' "$run_dir/events.jsonl" | head -1)
tokens=$(jq -r 'select(.type == "turn.completed") | .usage | "入力 \(.input_tokens) / 出力 \(.output_tokens)（うち推論 \(.reasoning_output_tokens)）"' "$run_dir/events.jsonl" | tail -1)

echo "## $title"
echo
echo "- 設定: $model / effort=$effort / fast=$fast_label"
echo "- 所要時間: $((SECONDS - started)) 秒、トークン: ${tokens:-不明}"
echo "- 保存先: $run_dir/review.md"
echo "- 続きを Codex と話す: codex resume $thread_id"
echo
cat "$run_dir/review.md"
echo
