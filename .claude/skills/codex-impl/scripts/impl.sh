#!/usr/bin/env bash
# Codex CLI（GPT-6 Luna、推論レベル max、Fast モード）に作業フォルダで実装させ、Codex が変えた差分を保存する。
#
# 使い方: impl.sh [--cd <dir>] [--resume <thread_id>] <実行フォルダ>
#   --cd      実装するリポジトリ（既定: 今のフォルダ）
#   --resume  前回の Codex のスレッドを再開し、<実行フォルダ>/feedback.md を修正の依頼として渡す
#   --resume がなければ <実行フォルダ>/task.md を実装の指示として渡す。
#
# Codex は workspace-write のサンドボックス（作業フォルダだけ書き込み可、ネットワークなし）で動く。
# 結果は回ごとに <実行フォルダ>/result-<回>.md、差分は diff-<回>.patch に保存する。
# 環境変数 CODEX_IMPL_MODEL でモデルを変えられる（既定: gpt-6-luna）。
set -euo pipefail

usage() { sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

workdir=$PWD run_dir="" thread=""
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; shift 2 || usage ;;
    --resume) thread=${2:-}; [[ -n $thread ]] || usage; shift 2 ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

model=${CODEX_IMPL_MODEL:-gpt-6-luna}

command -v codex >/dev/null || { echo "エラー: codex コマンドが見つかりません（brew install --cask codex）" >&2; exit 1; }
[[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
input=$run_dir/task.md
[[ -n $thread ]] && input=$run_dir/feedback.md
[[ -s $input ]] || { echo "エラー: $input がないか空です" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
workdir=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }

# 何回目の依頼か（結果ファイルの番号）
n=1
while [[ -e $run_dir/result-$n.md ]]; do n=$((n + 1)); done
[[ -n $thread || $n == 1 ]] || { echo "エラー: この実行フォルダは実装済みです。修正の依頼は --resume <thread_id> で渡してください" >&2; exit 1; }

# 作業ツリーの状態（未コミット・未追跡を含む）を、本物のインデックスに触れずにツリーとして記録する。
# 実行前後のツリーを比べれば、もとからあった未コミットの変更と混ざらずに Codex の変更だけを取り出せる。
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
snapshot() {
  local idx=$tmp/index real
  real=$(git -C "$workdir" rev-parse --path-format=absolute --git-path index)
  if [[ -f $real ]]; then cp "$real" "$idx"; else rm -f "$idx"; fi
  GIT_INDEX_FILE=$idx git -C "$workdir" add -A
  GIT_INDEX_FILE=$idx git -C "$workdir" write-tree
}
head_before=$(git -C "$workdir" rev-parse HEAD)
tree_before=$(snapshot)
dirty=""
[[ $tree_before == "$(git -C "$workdir" rev-parse 'HEAD^{tree}')" ]] || dirty=1

prompt=$run_dir/prompt-$n.md
if [[ -z $thread ]]; then
  {
    cat "$(dirname "$0")/../assets/impl-prompt.md"
    printf '\n\n<task>\n'
    cat "$input"
    printf '\n</task>\n'
  } >"$prompt"
else
  {
    echo "あなたの実装を Claude がレビューしました。次の依頼に対応してください。進め方と最後の報告の形式は最初の指示と同じです。"
    printf '\n<feedback>\n'
    cat "$input"
    printf '\n</feedback>\n'
  } >"$prompt"
fi

opts=(
  --ignore-user-config # 個人設定の MCP サーバーやプラグインを読み込まない
  --model "$model"
  -c 'model_reasoning_effort="max"'
  -c 'service_tier="fast"'
  -c 'sandbox_mode="workspace-write"'
  --json
  --output-last-message "$run_dir/result-$n.md"
)

echo "Codex で実装中（$n 回目）: model=$model effort=max fast=on 作業フォルダ=$workdir" >&2
started=$SECONDS
status=0
if [[ -z $thread ]]; then
  codex exec "${opts[@]}" --cd "$workdir" - <"$prompt" >"$run_dir/events-$n.jsonl" 2>"$run_dir/codex-$n.log" || status=$?
else
  (cd "$workdir" && codex exec resume "${opts[@]}" "$thread" -) <"$prompt" >"$run_dir/events-$n.jsonl" 2>"$run_dir/codex-$n.log" || status=$?
fi

# 失敗しても途中までの変更は残るので、差分は必ず保存する
head_after=$(git -C "$workdir" rev-parse HEAD)
tree_after=$(snapshot)
git -C "$workdir" diff --binary "$tree_before" "$tree_after" >"$run_dir/diff-$n.patch"
shortstat=$(git -C "$workdir" diff --shortstat "$tree_before" "$tree_after" | sed 's/^ *//')
stat=$(git -C "$workdir" diff --stat "$tree_before" "$tree_after")

if ((status != 0)) || [[ ! -s $run_dir/result-$n.md ]]; then
  echo "エラー: Codex の実行に失敗しました（終了コード $status）" >&2
  jq -r 'select(.type == "error" or .item.type == "error") | .message // .item.message' "$run_dir/events-$n.jsonl" 2>/dev/null | tail -5 >&2 || true
  tail -20 "$run_dir/codex-$n.log" >&2
  [[ -s $run_dir/diff-$n.patch ]] && echo "途中までの変更が作業フォルダに残っています: ${shortstat}（差分: $run_dir/diff-$n.patch）" >&2
  exit 1
fi

# Codex が警告として返したエラー（未対応の service tier など）を表示する
jq -r 'select(.item.type == "error") | "警告: " + .item.message' "$run_dir/events-$n.jsonl" >&2 || true

[[ -n $thread ]] || thread=$(jq -r 'select(.type == "thread.started") | .thread_id' "$run_dir/events-$n.jsonl" | head -1)
tokens=$(jq -r 'select(.type == "turn.completed") | .usage | "入力 \(.input_tokens)（うちキャッシュ \(.cached_input_tokens)）/ 出力 \(.output_tokens)（うち推論 \(.reasoning_output_tokens)）"' "$run_dir/events-$n.jsonl" | tail -1)

echo "## Codex の実装結果（$n 回目）"
echo
echo "- 設定: $model / effort=max / fast=on"
echo "- 作業フォルダ: $workdir"
echo "- 変更: ${shortstat:-なし}"
echo "- 所要時間: $((SECONDS - started)) 秒、トークン: ${tokens:-不明}"
echo "- 差分: $run_dir/diff-$n.patch"
echo "- スレッド: $thread（修正の依頼は --resume $thread）"
[[ -n $dirty && $n == 1 ]] && echo "- 注意: 実行前から未コミットの変更がありました。上の差分は Codex が変えた分だけです"
[[ $head_after == "$head_before" ]] || echo "- 注意: Codex が HEAD を動かしました（$(git -C "$workdir" rev-parse --short "$head_before") → $(git -C "$workdir" rev-parse --short "$head_after")）"
echo
cat "$run_dir/result-$n.md"
echo
if [[ -n $stat ]]; then printf '\n### 変更ファイル\n\n```\n%s\n```\n' "$stat"; fi
