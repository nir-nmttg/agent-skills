#!/usr/bin/env bash
# prepare.sh で作った prompt.md を Codex CLI（GPT-6.1 Sol）に読み取り専用でレビューさせ、review.md に保存する。
#
# 使い方: review.sh --effort <low|medium|high|xhigh|max> <実行フォルダ>
#   --effort  Codex の推論レベル。Claude の推論レベルをそのまま渡す（省略時は $CLAUDE_EFFORT、それもなければ high）
#
# 環境変数 CODEX_IMPL_REVIEW_MODEL でモデルを、CODEX_IMPL_REVIEW_TITLE で出力の見出しを変えられる
# （codex-risk-impl-review が使う）。
set -euo pipefail

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

effort="" run_dir=""
while (($#)); do
  case $1 in
    --effort) effort=${2:-}; shift 2 || usage ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

model=${CODEX_IMPL_REVIEW_MODEL:-gpt-6.1-sol}
title=${CODEX_IMPL_REVIEW_TITLE:-Codex の実装レビュー}
effort=${effort:-${CLAUDE_EFFORT:-}}
case $effort in
  low | medium | high | xhigh | max) ;;
  "" | auto) echo "注意: Claude の推論レベルがわからないため high で実行します" >&2; effort=high ;;
  *) echo "エラー: 推論レベル '$effort' には対応していません（low / medium / high / xhigh / max）" >&2; exit 1 ;;
esac

command -v codex >/dev/null || { echo "エラー: codex コマンドが見つかりません（brew install --cask codex）" >&2; exit 1; }
for f in prompt.md source.txt scope.txt; do
  [[ -s $run_dir/$f ]] || { echo "エラー: $run_dir/$f がありません。先に prepare.sh を実行してください" >&2; exit 1; }
done
run_dir=$(cd -P "$run_dir" && pwd)
source=$(cat "$run_dir/source.txt")
scope=$(cat "$run_dir/scope.txt")
[[ -d $source ]] || { echo "エラー: コードを読む場所 $source がありません" >&2; exit 1; }

args=(
  exec
  --ignore-user-config # 個人設定の MCP サーバーやプラグインを読み込まない
  --sandbox read-only
  --cd "$source" # --commit のときは展開した当時のソースで動かす
  --skip-git-repo-check
  --model "$model"
  -c "model_reasoning_effort=\"$effort\""
  # 1M コンテキストで動かす（モデルの上限を超えた分は Codex が上限に合わせる）。--ignore-user-config で
  # ユーザー設定を読まないので、ここで指定する
  -c model_context_window=1000000
  -c model_auto_compact_token_limit=900000
  # プロジェクトの指示は prompt.md で渡す。--commit のソースはスキル集の下にあるので、自動で読むとスキル集の AGENTS.md が混ざる
  -c project_doc_max_bytes=0
  --json
)

started=$SECONDS
echo "Codex でレビュー中: model=$model effort=$effort 範囲=$scope" >&2
rm -f "$run_dir/review.md"
status=0
# 実行フォルダはスキル集のリポジトリの下にあるので、展開したソースで git が親のリポジトリを見つけないようにする
GIT_CEILING_DIRECTORIES=$run_dir codex "${args[@]}" --output-last-message "$run_dir/review.md" - <"$run_dir/prompt.md" \
  >"$run_dir/events.jsonl" 2>"$run_dir/codex.log" || status=$?

if ((status != 0)) || [[ ! -s $run_dir/review.md ]]; then
  echo "エラー: Codex の実行に失敗しました（終了コード ${status}）" >&2
  jq -r 'select(.type == "error" or .item.type == "error") | .message // .item.message' "$run_dir/events.jsonl" 2>/dev/null | tail -5 >&2 || true
  tail -20 "$run_dir/codex.log" >&2
  exit 1
fi
# Codex が警告として返したエラーを表示する
jq -r 'select(.item.type == "error") | "警告: \(.item.message)"' "$run_dir/events.jsonl" >&2 || true

thread=$(jq -r 'select(.type == "thread.started") | .thread_id' "$run_dir/events.jsonl" | head -1) || true
tokens=$(jq -r 'select(.type == "turn.completed") | .usage | "入力 \(.input_tokens) / 出力 \(.output_tokens)（うち推論 \(.reasoning_output_tokens)）"' "$run_dir/events.jsonl" | tail -1) || true

echo "## $title"
echo
echo "- 設定: $model / effort=$effort / context=1M"
echo "- 範囲: $scope"
echo "- 所要時間: $((SECONDS - started)) 秒、トークン: ${tokens:-不明}"
echo "- 保存先: $run_dir/review.md"
echo "- 続きを Codex と話す: codex resume ${thread:-不明}"
echo
cat "$run_dir/review.md"
echo
