#!/usr/bin/env bash
# 作業フォルダの git の変更を Codex CLI（GPT-6.1 Sol）に読み取り専用でレビューさせ、review.md に保存する。
#
# 使い方: review.sh --effort <low|medium|high|xhigh|max> [--fast] [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] [--focus <観点>[,<観点>...]] <実行フォルダ>
#   --effort       Codex の推論レベル。Claude の推論レベルをそのまま渡す（省略時は $CLAUDE_EFFORT、それもなければ high）
#   --fast         Fast モード（service_tier=fast）で実行する。速いぶん使用量が増える
#   --cd           レビューするリポジトリ（既定: 今のフォルダ）
#   --base         <ref> から分岐して以降の変更（コミット済み＋未コミット）をレビューする
#   --commit       1 つのコミットだけをレビューする
#   --uncommitted  未コミットの変更（ステージ済み・未ステージ・未追跡）だけをレビューする
#   範囲を指定しなければ、既定ブランチ（origin/HEAD、なければ main / master）からの変更をすべてレビューする。
#   --focus        観点ごとに分けて、観点の数だけ Codex を並列に動かす。結果は review-<観点>.md に保存する
#                  観点は assets/focus/ のファイル名（correctness / reliability / security / maintainability）
#
# 環境変数 CODEX_IMPL_REVIEW_MODEL でモデルを、CODEX_IMPL_REVIEW_PROMPT でレビューの指示書を、
# CODEX_IMPL_REVIEW_TITLE で出力の見出しを変えられる（codex-risk-impl-review が使う）。
# 観点の定義は指示書と同じフォルダの focus/ から読む。
set -euo pipefail

usage() { sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

effort="" fast="" workdir=$PWD run_dir="" mode=auto target="" focus_arg=""
while (($#)); do
  case $1 in
    --effort) effort=${2:-}; shift 2 || usage ;;
    --fast) fast=1; shift ;;
    --cd) workdir=${2:-}; shift 2 || usage ;;
    --focus) focus_arg=${2:-}; [[ -n $focus_arg ]] || usage; shift 2 ;;
    --base | --commit)
      [[ $mode == auto ]] || usage
      mode=${1#--}; target=${2:-}; [[ -n $target ]] || usage; shift 2 ;;
    --uncommitted) [[ $mode == auto ]] || usage; mode=uncommitted; shift ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

model=${CODEX_IMPL_REVIEW_MODEL:-gpt-6.1-sol}
prompt_file=${CODEX_IMPL_REVIEW_PROMPT:-$(dirname "$0")/../assets/review-prompt.md}
title=${CODEX_IMPL_REVIEW_TITLE:-Codex の実装レビュー}
effort=${effort:-${CLAUDE_EFFORT:-}}
case $effort in
  low | medium | high | xhigh | max) ;;
  "" | auto) echo "注意: Claude の推論レベルがわからないため high で実行します" >&2; effort=high ;;
  *) echo "エラー: 推論レベル '$effort' には対応していません（low / medium / high / xhigh / max）" >&2; exit 1 ;;
esac

command -v codex >/dev/null || { echo "エラー: codex コマンドが見つかりません（brew install --cask codex）" >&2; exit 1; }
[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
[[ -f $run_dir/context.md ]] || { echo "エラー: $run_dir/context.md がありません" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
toplevel=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
workdir=$toplevel
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }

focus_dir=$(dirname "$prompt_file")/focus
focuses=()
if [[ -n $focus_arg ]]; then
  IFS=, read -ra focuses <<<"$focus_arg"
  available=$(ls "$focus_dir" 2>/dev/null | sed -n 's/\.md$//p' | paste -sd, - || true)
  for f in "${focuses[@]}"; do
    [[ $f =~ ^[a-z][a-z0-9-]*$ && -f $focus_dir/$f.md ]] ||
      { echo "エラー: 観点 '$f' はありません（使える観点: ${available:-なし}）" >&2; exit 1; }
  done
  dups=$(printf '%s\n' "${focuses[@]}" | sort | uniq -d | paste -sd, -)
  [[ -z $dups ]] || { echo "エラー: 観点 '$dups' が重複しています" >&2; exit 1; }
fi

g() { git -C "$workdir" "$@"; }

# レビューする範囲を決め、差分を diff.patch に書き出す
untracked=()
if [[ $mode == commit ]]; then
  sha=$(g rev-parse -q --verify "$target^{commit}") || { echo "エラー: コミット '$target' が見つかりません" >&2; exit 1; }
  scope="コミット $(g log -1 --format='%h %s' "$sha")"
  commits=$(g log -1 --format='%h %s%n%n%b' "$sha")
  # マージコミットは combined diff だと取り込んだ変更が出ないので、第一親との差分にする
  if g rev-parse -q --verify "$sha^1" >/dev/null; then
    view_cmd="git diff $sha^1 $sha"
    stat=$(g diff --stat "$sha^1" "$sha")
    g diff "$sha^1" "$sha" >"$run_dir/diff.patch"
  else
    view_cmd="git show $sha"
    stat=$(g show --format= --stat "$sha")
    g show --format= --patch "$sha" >"$run_dir/diff.patch"
  fi
else
  if [[ $mode == uncommitted ]]; then
    from=$(g rev-parse HEAD)
    scope="未コミットの変更（HEAD $(g rev-parse --short HEAD) からの差分）"
  else
    if [[ $mode == auto ]]; then
      target=$(g symbolic-ref -q --short refs/remotes/origin/HEAD) ||
        for b in main master; do g rev-parse -q --verify "$b^{commit}" >/dev/null && { target=$b; break; }; done
      [[ -n $target ]] || { echo "エラー: 既定ブランチがわかりません。--base か --commit か --uncommitted で範囲を指定してください" >&2; exit 1; }
    fi
    g rev-parse -q --verify "$target^{commit}" >/dev/null || { echo "エラー: '$target' が見つかりません" >&2; exit 1; }
    from=$(g merge-base "$target" HEAD) || { echo "エラー: '$target' と HEAD の共通の祖先がありません" >&2; exit 1; }
    scope="$target から分岐して以降の変更（$(g rev-parse --short "$from") からの差分。未コミットの変更を含む）"
  fi
  view_cmd="git diff $from"
  commits=$(g log --format='%h %s' "$from..HEAD")
  stat=$(g diff --stat "$from")
  g diff "$from" >"$run_dir/diff.patch"
  while IFS= read -r -d '' f; do untracked+=("$f"); done < <(g ls-files -z --others --exclude-standard)
  for f in ${untracked[@]+"${untracked[@]}"}; do
    # --no-index は差分があると 1 で終わる。それ以外の失敗は取りこぼしになるので止める
    rc=0
    (cd "$workdir" && git diff --no-index -- /dev/null "$f" >>"$run_dir/diff.patch") || rc=$?
    ((rc <= 1)) || { echo "エラー: 未追跡ファイル '$f' の差分を作れませんでした" >&2; exit 1; }
  done
fi

if [[ ! -s $run_dir/diff.patch ]]; then
  echo "エラー: レビューする変更がありません（範囲: ${scope}）。--base / --commit / --uncommitted で範囲を指定してください" >&2
  exit 1
fi
files=$(grep -c '^diff --git ' "$run_dir/diff.patch" || true)
lines=$(grep -E '^[+-]' "$run_dir/diff.patch" | grep -cvE '^(\+\+\+|---) ' || true)

# 大きすぎる差分はプロンプトに埋め込まず、Codex に git コマンドで読ませる
max_bytes=200000
size=$(wc -c <"$run_dir/diff.patch" | tr -d ' ')

# レビュー対象（範囲・説明・差分）を出力する。観点を分けても全員に同じものを渡す
payload() {
  printf '\n\n<scope>\n'
  echo "リポジトリ: $workdir"
  echo "範囲: $scope"
  if [[ -n $commits ]]; then printf '\nコミット:\n%s\n' "$commits"; fi
  if [[ -n $stat ]]; then printf '\n変更ファイル:\n%s\n' "$stat"; fi
  if ((${#untracked[@]})); then printf '\n未追跡の新規ファイル:\n'; printf '%s\n' "${untracked[@]}"; fi
  printf '</scope>\n\n<context>\n'
  cat "$run_dir/context.md"
  printf '\n</context>\n\n<diff>\n'
  if ((size <= max_bytes)); then
    cat "$run_dir/diff.patch"
  else
    echo "差分が大きい（${size} バイト）ため埋め込んでいません。\`$view_cmd\` で確認してください（未追跡の新規ファイルは直接読んでください）。"
  fi
  printf '</diff>\n'
}

args=(
  exec
  --ignore-user-config # 個人設定の MCP サーバーやプラグインを読み込まない
  --sandbox read-only
  --cd "$workdir"
  --model "$model"
  -c "model_reasoning_effort=\"$effort\""
  --json
)
fast_label=off
[[ -n $fast ]] && { args+=(-c 'service_tier="fast"'); fast_label=on; }

# 1 つの観点（空なら全観点）についてプロンプトを組み立て、Codex を実行する。Codex の終了コードを返す
run_review() {
  local focus=$1 sfx=${1:+-$1} status=0
  {
    cat "$prompt_file"
    if [[ -n $focus ]]; then
      printf '\n\n## 今回の担当\n\n'
      echo 'このレビューは観点ごとに分けて、複数のレビュアーが並行して行っています。あなたの担当は次の観点だけです。上の「観点」のうち担当外のものはほかのレビュアーが見るので、深追いしないでください。担当外でも重要度「高」の問題に気づいたときは、「指摘」の最後に見出しへ「[担当外]」を付けて簡潔に挙げてください。出力形式は上と同じです。'
      echo
      cat "$focus_dir/$focus.md"
    fi
    payload
  } >"$run_dir/prompt$sfx.md"
  codex "${args[@]}" --output-last-message "$run_dir/review$sfx.md" - <"$run_dir/prompt$sfx.md" \
    >"$run_dir/events$sfx.jsonl" 2>"$run_dir/codex$sfx.log" || status=$?
  return "$status"
}

# 失敗していればエラーを表示して 1 を返す。成功なら Codex の警告だけを表示する
check_result() {
  local sfx=$1 status=$2 label=${3:+観点 $3、}
  if ((status != 0)) || [[ ! -s $run_dir/review$sfx.md ]]; then
    echo "エラー: Codex の実行に失敗しました（${label}終了コード ${status}）" >&2
    jq -r 'select(.type == "error" or .item.type == "error") | .message // .item.message' "$run_dir/events$sfx.jsonl" 2>/dev/null | tail -5 >&2 || true
    tail -20 "$run_dir/codex$sfx.log" >&2
    return 1
  fi
  # Codex が警告として返したエラー（未対応の service tier など）を表示する
  jq -r 'select(.item.type == "error") | "警告: \(.item.message)"' "$run_dir/events$sfx.jsonl" >&2 || true
}

thread_of() { jq -r 'select(.type == "thread.started") | .thread_id' "$run_dir/events$1.jsonl" | head -1; }
tokens_of() {
  local t
  t=$(jq -r 'select(.type == "turn.completed") | .usage | "入力 \(.input_tokens) / 出力 \(.output_tokens)（うち推論 \(.reasoning_output_tokens)）"' "$run_dir/events$1.jsonl" | tail -1)
  echo "${t:-不明}"
}

started=$SECONDS

if ((${#focuses[@]} == 0)); then
  echo "Codex でレビュー中: model=$model effort=$effort fast=$fast_label 範囲=${scope}（$files ファイル、$lines 行）" >&2
  status=0
  run_review "" || status=$?
  check_result "" "$status" || exit 1

  echo "## $title"
  echo
  echo "- 設定: $model / effort=$effort / fast=$fast_label"
  echo "- 範囲: ${scope}（$files ファイル、$lines 行）"
  echo "- 所要時間: $((SECONDS - started)) 秒、トークン: $(tokens_of "")"
  echo "- 保存先: $run_dir/review.md"
  echo "- 続きを Codex と話す: codex resume $(thread_of "")"
  echo
  cat "$run_dir/review.md"
  echo
  exit 0
fi

echo "Codex で観点ごとに並列レビュー中: ${focuses[*]} model=$model effort=$effort fast=$fast_label 範囲=${scope}（$files ファイル、$lines 行）" >&2
pids=()
for f in "${focuses[@]}"; do
  run_review "$f" &
  pids+=($!)
done
statuses=()
for pid in "${pids[@]}"; do
  s=0
  wait "$pid" || s=$?
  statuses+=("$s")
done

echo "## ${title}（観点ごとに並列）"
echo
echo "- 設定: $model / effort=$effort / fast=$fast_label"
echo "- 範囲: ${scope}（$files ファイル、$lines 行）"
echo "- 観点: $(IFS=,; echo "${focuses[*]}")"
echo "- 所要時間: $((SECONDS - started)) 秒（すべての観点が終わるまで）"
echo
failed=()
for i in "${!focuses[@]}"; do
  f=${focuses[$i]}
  check_result "-$f" "${statuses[$i]}" "$f" || { failed+=("$f"); continue; }
  echo "---"
  echo
  echo "## 観点: $f"
  echo
  echo "- トークン: $(tokens_of "-$f")"
  echo "- 保存先: $run_dir/review-$f.md"
  echo "- 続きを Codex と話す: codex resume $(thread_of "-$f")"
  echo
  cat "$run_dir/review-$f.md"
  echo
done

if ((${#failed[@]})); then
  echo "エラー: 次の観点のレビューに失敗しました: $(IFS=,; echo "${failed[*]}")" >&2
  exit 1
fi
