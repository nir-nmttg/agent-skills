#!/usr/bin/env bash
# Codex CLI（GPT-6 Luna、推論レベル max、通常速度）にテストを実行させ、結果の報告を出力する。
#
# 使い方: run.sh [--cd <dir>] [--network] [--resume <実行フォルダ>] [<依頼>]
#   --cd       テストを実行するリポジトリ（既定: 今のフォルダ）
#   --network  サンドボックスからのネットワーク（localhost の DB なども含む）を許可する
#   --resume   前回の実行フォルダの Codex のスレッドを再開し、<依頼> を渡す（既定: 前回失敗したテストの再実行）
#   <依頼>     実行するコマンドや範囲（省略時は Codex がテストの実行方法を調べて一通り実行する）
#
# Codex は workspace-write のサンドボックス（作業フォルダだけ書き込み可、既定でネットワークなし）で動き、
# ファイルを変更しないよう指示する。それでも追跡対象のファイルが変わったら差分を保存して警告する。
# 保存先は $CODEX_TEST_DIR（既定: このリポジトリ直下の artifacts/codex-test）/<日時>-<リポジトリ名>/。
# 回ごとに result-<回>.md（報告）、commands-<回>.log（Codex が実行したコマンドと出力の全文）を保存する。
# 環境変数 CODEX_TEST_MODEL でモデルを変えられる（既定: gpt-6-luna）。
set -euo pipefail

usage() { sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

workdir=$PWD network="" run_dir=""
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; shift 2 || usage ;;
    --network) network=1; shift ;;
    --resume) run_dir=${2:-}; [[ -n $run_dir ]] || usage; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
request=$*

model=${CODEX_TEST_MODEL:-gpt-6-luna}

command -v codex >/dev/null || { echo "エラー: codex コマンドが見つかりません（brew install --cask codex）" >&2; exit 1; }
command -v jq >/dev/null || { echo "エラー: jq コマンドが見つかりません（brew install jq）" >&2; exit 1; }

# 作業ツリーの状態（未コミット・未追跡を含む、.gitignore 対象は除く）を、本物のインデックスに触れずに記録する
snapshot() {
  local idx real
  idx=$(mktemp "${TMPDIR:-/tmp}/codex-test-index.XXXXXX")
  real=$(git -C "$workdir" rev-parse --path-format=absolute --git-path index)
  if [[ -f $real ]]; then cp "$real" "$idx"; else rm -f "$idx"; fi
  GIT_INDEX_FILE=$idx git -C "$workdir" add -A -- .
  GIT_INDEX_FILE=$idx git -C "$workdir" write-tree
  rm -f "$idx"
}

if [[ -n $run_dir ]]; then
  [[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
  run_dir=$(cd -P "$run_dir" && pwd)
  [[ -s $run_dir/thread && -s $run_dir/workdir ]] || { echo "エラー: $run_dir に前回のスレッドの記録がありません" >&2; exit 1; }
  thread=$(<"$run_dir/thread") workdir=$(<"$run_dir/workdir")
  [[ -s $run_dir/network ]] && network=1
else
  [[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
  workdir=$(cd -P "$workdir" && pwd)
  workdir=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null || echo "$workdir")
  thread=""
  # ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
  repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
  slug=$(basename "$workdir" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-40)
  run_dir=${CODEX_TEST_DIR:-$repo_root/artifacts/codex-test}/$(date +%Y%m%d-%H%M%S)-${slug%-}
  mkdir -p "$run_dir"
  echo "$workdir" >"$run_dir/workdir"
  [[ -n $network ]] && echo 1 >"$run_dir/network"
fi

# 何回目の実行か（結果ファイルの番号）
n=1
while [[ -e $run_dir/result-$n.md ]]; do n=$((n + 1)); done

prompt=$run_dir/prompt-$n.md
if [[ -z $thread ]]; then
  {
    cat "$(dirname "$0")/../assets/test-prompt.md"
    printf '\n\n<task>\n%s\n</task>\n' "${request:-このリポジトリのテストを一通り実行してください。}"
  } >"$prompt"
else
  {
    echo "Claude がコードを直しました。次の依頼に対応してください。守ることと最後の報告の形式は最初の指示と同じです。"
    printf '\n<task>\n%s\n</task>\n' "${request:-前回失敗したテストと、実行できなかったテストを再実行してください。}"
  } >"$prompt"
fi

is_git=""
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null 2>&1 && is_git=1
[[ -n $is_git ]] && tree_before=$(snapshot)

opts=(
  --ignore-user-config # 個人設定の MCP サーバーやプラグイン、service_tier を読み込まない（通常速度で動く）
  --model "$model"
  -c 'model_reasoning_effort="max"'
  -c 'sandbox_mode="workspace-write"'
  --json
  --output-last-message "$run_dir/result-$n.md"
)
net_label=off
[[ -n $network ]] && { opts+=(-c 'sandbox_workspace_write.network_access=true'); net_label=on; }

echo "Codex でテスト中（$n 回目）: model=$model effort=max fast=off network=$net_label 作業フォルダ=$workdir" >&2
started=$SECONDS
status=0
if [[ -z $thread ]]; then
  codex exec "${opts[@]}" --skip-git-repo-check --cd "$workdir" - <"$prompt" >"$run_dir/events-$n.jsonl" 2>"$run_dir/codex-$n.log" || status=$?
else
  (cd "$workdir" && codex exec resume "${opts[@]}" --skip-git-repo-check "$thread" -) <"$prompt" >"$run_dir/events-$n.jsonl" 2>"$run_dir/codex-$n.log" || status=$?
fi

# Codex が実行したコマンドと出力の全文（Claude が必要なときだけ Grep する）
jq -r 'select(.type == "item.completed" and .item.type == "command_execution") | .item
  | "$ \(.command)\n[終了コード \(.exit_code // "不明")]\n\(.aggregated_output // "")\n"' \
  "$run_dir/events-$n.jsonl" >"$run_dir/commands-$n.log" 2>/dev/null || true

# Codex がファイルを変えていないか確かめる
changed=""
if [[ -n $is_git ]]; then
  tree_after=$(snapshot)
  if [[ $tree_after != "$tree_before" ]]; then
    git -C "$workdir" diff --binary "$tree_before" "$tree_after" >"$run_dir/diff-$n.patch"
    changed=$(git -C "$workdir" diff --shortstat "$tree_before" "$tree_after" | sed 's/^ *//')
  fi
fi

if ((status != 0)) || [[ ! -s $run_dir/result-$n.md ]]; then
  echo "エラー: Codex の実行に失敗しました（終了コード ${status}）" >&2
  jq -r 'select(.type == "error" or .item.type == "error") | .message // .item.message' "$run_dir/events-$n.jsonl" 2>/dev/null | tail -5 >&2 || true
  tail -20 "$run_dir/codex-$n.log" >&2
  [[ -n $changed ]] && echo "注意: Codex がファイルを変更しました: ${changed}（差分: $run_dir/diff-$n.patch）" >&2
  exit 1
fi

jq -r 'select(.item.type == "error") | "警告: " + .item.message' "$run_dir/events-$n.jsonl" >&2 || true

if [[ -z $thread ]]; then
  thread=$(jq -r 'select(.type == "thread.started") | .thread_id' "$run_dir/events-$n.jsonl" | head -1)
  echo "$thread" >"$run_dir/thread"
fi
tokens=$(jq -r 'select(.type == "turn.completed") | .usage | "入力 \(.input_tokens)（うちキャッシュ \(.cached_input_tokens)）/ 出力 \(.output_tokens)（うち推論 \(.reasoning_output_tokens)）"' "$run_dir/events-$n.jsonl" | tail -1)
ncmd=$(grep -c '^\$ ' "$run_dir/commands-$n.log" || true)

echo "## Codex のテスト結果（$n 回目）"
echo
echo "- 設定: $model / effort=max / fast=off / network=$net_label"
echo "- 作業フォルダ: $workdir"
echo "- 所要時間: $((SECONDS - started)) 秒、トークン: ${tokens:-不明}"
echo "- 実行ログ: $run_dir/commands-$n.log（コマンド $ncmd 件）"
echo "- 再実行: run.sh --resume $run_dir [<依頼>]"
[[ -n $changed ]] && echo "- 注意: Codex がファイルを変更しました: ${changed}（差分: $run_dir/diff-$n.patch）"
[[ -z $is_git ]] && echo "- 注意: git リポジトリではないため、Codex がファイルを変えていないかは確かめていません"
echo
cat "$run_dir/result-$n.md"
