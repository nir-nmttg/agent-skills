#!/usr/bin/env bash
# Codex CLI（GPT-6 Luna、推論レベル max、Fast モード）に実装させ、Codex が変えた差分を保存する。
#
# 使い方: impl.sh [--cd <dir>] [--worktree] [--resume <thread_id>] [--test <コマンド>] [--test-retries <回数>] <実行フォルダ>
#   --cd        実装するリポジトリ（既定: 今のフォルダ）
#   --worktree  作業フォルダではなく、専用の git worktree（<実行フォルダ>/worktree）で実装させる。
#               並行して何本も動かすときや、その間に Claude が作業フォルダで作業するときに使う。
#               結果は apply.sh で作業フォルダに反映する（2 回目以降は自動で同じ worktree を使う）
#   --resume    前回の Codex のスレッドを再開し、<実行フォルダ>/feedback.md を修正の依頼として渡す
#   --test      Codex が終わるたびに、サンドボックスの外でこのコマンドを実行する（DB や Docker が要るテスト用）。
#               失敗したら出力を添えて自動で Codex に差し戻す。2 回目以降の依頼でも同じコマンドを使う
#   --test-retries  テストが失敗したときに自動で差し戻す回数（既定: 2）
#   --resume がなければ <実行フォルダ>/task.md を実装の指示として渡す。
#
# Codex は workspace-write のサンドボックス（作業フォルダだけ書き込み可、ネットワークなし）で動く。
# 結果は回ごとに <実行フォルダ>/result-<回>.md、差分は diff-<回>.patch、テストの出力は test-<回>.log に保存する。
# 自動で差し戻した回があれば、この依頼の全体の差分を diff-<最初の回>-<最後の回>.patch にも保存する。
# テストのコマンドは bash -c で、実装している場所（worktree または作業フォルダ）をカレントにして実行する。
# 環境変数 CODEX_IMPL_WORKDIR（実装している場所）、CODEX_IMPL_REPO（もとのリポジトリ）、CODEX_IMPL_RUN_DIR を渡す。
# テストは実行フォルダの親フォルダのロックで 1 本ずつ実行する（並行で動かす Codex どうしが DB を取り合わないように）。
# テストが通らないまま差し戻しの上限に達したら、終了コード 3 で終わる。
# 環境変数 CODEX_IMPL_MODEL でモデルを変えられる（既定: gpt-6-luna）。
# worktree には、作業フォルダにある依存パッケージのフォルダ（.gitignore 対象の node_modules / .venv / venv /
# .bundle / vendor。CODEX_IMPL_LINK_DIRS で変えられる）をシンボリックリンクする。
set -euo pipefail

usage() { sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
source "$(dirname "$0")/lib.sh"

workdir=$PWD run_dir="" thread="" use_worktree="" test_cmd="" retries=2
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; shift 2 || usage ;;
    --worktree) use_worktree=1; shift ;;
    --resume) thread=${2:-}; [[ -n $thread ]] || usage; shift 2 ;;
    --test) test_cmd=${2:-}; [[ -n $test_cmd ]] || usage; shift 2 ;;
    --test-retries) retries=${2:-}; [[ $retries =~ ^[0-9]+$ ]] || usage; shift 2 ;;
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

# テストのコマンドは実行フォルダに残し、2 回目以降の依頼でも使う
if [[ -n $test_cmd ]]; then
  printf '%s\n' "$test_cmd" >"$run_dir/test-cmd"
elif [[ -s $run_dir/test-cmd ]]; then
  test_cmd=$(<"$run_dir/test-cmd")
fi

# 何回目の依頼か（結果ファイルの番号）
n=1
while [[ -e $run_dir/result-$n.md ]]; do n=$((n + 1)); done
[[ -n $thread || $n == 1 ]] || { echo "エラー: この実行フォルダは実装済みです。修正の依頼は --resume <thread_id> で渡してください" >&2; exit 1; }

wt=$run_dir/worktree excl=""
if [[ -f $run_dir/repo ]]; then
  # 前回 worktree で実装した実行フォルダ
  [[ -d $wt ]] || { echo "エラー: $wt がありません（反映・破棄済みです）。続きは新しい実行フォルダで依頼してください" >&2; exit 1; }
  repo=$(<"$run_dir/repo")
  workdir=$wt excl=$run_dir/linked
else
  [[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
  workdir=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
  git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }
  repo=$workdir
  if [[ -n $use_worktree ]]; then
    # 作業フォルダの今の状態（未コミットの変更を含む）を HEAD の子コミットにし、そこから worktree を切る。
    # ブランチや本物のインデックスには触れない
    base_tree=$(snapshot "$repo")
    echo "$base_tree" >"$run_dir/base-tree"
    base_commit=$(GIT_AUTHOR_NAME=codex-impl GIT_AUTHOR_EMAIL=codex-impl@localhost \
      GIT_COMMITTER_NAME=codex-impl GIT_COMMITTER_EMAIL=codex-impl@localhost \
      git -C "$repo" commit-tree "$base_tree" -p HEAD -m "codex-impl base")
    git -C "$repo" -c core.hooksPath=/dev/null worktree add -q --detach "$wt" "$base_commit"
    # 依存パッケージのフォルダをリンクし、Codex がテストを動かせるようにする（差分からは除く）
    : >"$run_dir/linked"
    link_names=" ${CODEX_IMPL_LINK_DIRS:-node_modules .venv venv .bundle vendor} "
    while IFS= read -r -d '' d; do
      d=${d%/}
      [[ $link_names == *" ${d##*/} "* && ! -e $wt/$d ]] || continue
      mkdir -p "$(dirname "$wt/$d")"
      ln -s "$repo/$d" "$wt/$d"
      echo "$d" >>"$run_dir/linked"
    done < <(git -C "$repo" ls-files -z --others --ignored --exclude-standard --directory)
    echo "$repo" >"$run_dir/repo"
    workdir=$wt excl=$run_dir/linked
  fi
fi

head_start=$(git -C "$workdir" rev-parse HEAD) first_n=$n
tree_start=$(snapshot "$workdir" "$excl") dirty=""
[[ $tree_start == "$(git -C "$workdir" rev-parse 'HEAD^{tree}')" ]] || dirty=1

opts=(
  --ignore-user-config # 個人設定の MCP サーバーやプラグインを読み込まない
  --model "$model"
  -c 'model_reasoning_effort="max"'
  -c 'service_tier="fast"'
  -c 'sandbox_mode="workspace-write"'
  --json
)

# run_codex  $prompt を Codex に渡して実装させ、$n 回目の結果と差分を保存する（$thread があれば再開）
run_codex() {
  local tree_before tree_after status=0
  tree_before=$(snapshot "$workdir" "$excl")
  echo "Codex で実装中（$n 回目）: model=$model effort=max fast=on 作業フォルダ=$workdir" >&2
  started=$SECONDS
  if [[ -z $thread ]]; then
    codex exec "${opts[@]}" --output-last-message "$run_dir/result-$n.md" --cd "$workdir" - \
      <"$prompt" >"$run_dir/events-$n.jsonl" 2>"$run_dir/codex-$n.log" || status=$?
  else
    (cd "$workdir" && codex exec resume "${opts[@]}" --output-last-message "$run_dir/result-$n.md" "$thread" -) \
      <"$prompt" >"$run_dir/events-$n.jsonl" 2>"$run_dir/codex-$n.log" || status=$?
  fi

  # 失敗しても途中までの変更は残るので、差分は必ず保存する
  tree_after=$(snapshot "$workdir" "$excl")
  git -C "$workdir" diff --binary "$tree_before" "$tree_after" >"$run_dir/diff-$n.patch"
  shortstat=$(git -C "$workdir" diff --shortstat "$tree_before" "$tree_after" | sed 's/^ *//')
  stat=$(git -C "$workdir" diff --stat "$tree_before" "$tree_after")

  if ((status != 0)) || [[ ! -s $run_dir/result-$n.md ]]; then
    echo "エラー: Codex の実行に失敗しました（終了コード ${status}）" >&2
    jq -r 'select(.type == "error" or .item.type == "error") | .message // .item.message' "$run_dir/events-$n.jsonl" 2>/dev/null | tail -5 >&2 || true
    tail -20 "$run_dir/codex-$n.log" >&2
    [[ -s $run_dir/diff-$n.patch ]] && echo "途中までの変更が $workdir に残っています: ${shortstat}（差分: $run_dir/diff-$n.patch）" >&2
    exit 1
  fi

  # Codex が警告として返したエラー（未対応の service tier など）を表示する
  jq -r 'select(.item.type == "error") | "警告: " + .item.message' "$run_dir/events-$n.jsonl" >&2 || true

  [[ -n $thread ]] || thread=$(jq -r 'select(.type == "thread.started") | .thread_id' "$run_dir/events-$n.jsonl" | head -1)
  tokens=$(jq -r 'select(.type == "turn.completed") | .usage | "入力 \(.input_tokens)（うちキャッシュ \(.cached_input_tokens)）/ 出力 \(.output_tokens)（うち推論 \(.reasoning_output_tokens)）"' "$run_dir/events-$n.jsonl" | tail -1)
}

lock=$(dirname "$run_dir")/.test-lock

# locked <コマンド>...  ほかの実行フォルダのテストが終わるのを待ってからコマンドを実行する（待ちのメッセージは fd 3 に出す）。
# macOS に flock コマンドがないため perl の flock を使う。ロックのファイルをコマンドに引き継ぐので、
# impl.sh だけが止められてもテストが終わるまでロックが残り、プロセスが終われば自動で外れる
locked() {
  perl -MFcntl=:flock -mPOSIX -e '
    $^F = 255; # ロックのファイルを exec の先に引き継ぐ
    open(my $fh, ">>", shift) or die "ロックを開けません: $!\n";
    unless (flock($fh, LOCK_EX | LOCK_NB)) {
      if (open(my $msg, ">&=3")) { print $msg "テストの順番待ち: ほかの実行フォルダのテストが終わるのを待っています\n" }
      flock($fh, LOCK_EX) or die "ロックできません: $!\n";
    }
    POSIX::close(3); # 待ちのメッセージ用の fd はコマンドに渡さない
    exec @ARGV or die "実行できません: $!\n";
  ' "$lock" "$@"
}

# run_test  テストのコマンドを 1 本ずつ実行し、出力を test-$n.log に、終了コードを test_status に残す
run_test() {
  local before after
  echo "テストを実行中（$n 回目）: $test_cmd" >&2
  before=$(snapshot "$workdir" "$excl")
  test_started=$SECONDS test_status=0
  (cd "$workdir" && CODEX_IMPL_WORKDIR=$workdir CODEX_IMPL_REPO=$repo CODEX_IMPL_RUN_DIR=$run_dir \
    locked bash -c "$test_cmd") 3>&2 </dev/null >"$run_dir/test-$n.log" 2>&1 || test_status=$?
  test_secs=$((SECONDS - test_started))
  # テストの実行で追跡対象のファイルが変わったら、取り違えないように残して知らせる
  after=$(snapshot "$workdir" "$excl")
  test_changed=""
  if [[ $before != "$after" ]]; then
    git -C "$workdir" diff --binary "$before" "$after" >"$run_dir/test-$n.patch"
    test_changed=$(git -C "$workdir" diff --shortstat "$before" "$after" | sed 's/^ *//')
  fi
}

# summary  $n 回目の設定・変更・テストの結果を短く表示する
summary() {
  echo "## Codex の実装結果（$n 回目）"
  echo
  echo "- 設定: $model / effort=max / fast=on"
  if [[ $workdir == "$wt" ]]; then
    echo "- 作業場所: ${wt}（$repo の worktree。反映は apply.sh ${run_dir}）"
  else
    echo "- 作業フォルダ: $workdir"
  fi
  echo "- 変更: ${shortstat:-なし}"
  echo "- 所要時間: $((SECONDS - started)) 秒、トークン: ${tokens:-不明}"
  echo "- 差分: $run_dir/diff-$n.patch"
  echo "- スレッド: ${thread}（修正の依頼は --resume ${thread}）"
  if [[ -n $test_cmd ]]; then
    if ((test_status == 0)); then echo "- テスト: 成功（$test_secs 秒、出力: $run_dir/test-$n.log）"
    else echo "- テスト: 失敗（終了コード $test_status、$test_secs 秒、出力: $run_dir/test-$n.log）"
    fi
    [[ -z $test_changed ]] || echo "- 注意: テストの実行で追跡対象のファイルが変わりました: ${test_changed}（差分: $run_dir/test-$n.patch）"
  fi
}

prompt=$run_dir/prompt-$n.md
if [[ -z $thread ]]; then
  {
    cat "$(dirname "$0")/../assets/impl-prompt.md"
    if [[ -n $test_cmd ]]; then
      printf '\n## サンドボックスの外でのテスト\n\n'
      echo "実装が終わるたびに、Claude が用意したスクリプトがサンドボックスの外で次のコマンドを実行します。失敗したら、その出力を添えて修正を依頼します。あなたのサンドボックスからは実行できないことがあるので、実行できなくても報告に書くだけで構いません。"
      printf '\n```bash\n%s\n```\n' "$test_cmd"
    fi
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

attempt=0 test_status=0 history=()
while :; do
  run_codex
  [[ -n $test_cmd ]] || break
  run_test
  ((test_status != 0 && attempt < retries)) || break
  # テストが失敗したので、出力を添えて差し戻す（途中の回は 1 行だけ残す）
  history+=("$n 回目: 変更 ${shortstat:-なし}、$((SECONDS - started)) 秒、テスト失敗（終了コード ${test_status}、出力: $run_dir/test-$n.log）${test_changed:+。注意: テストの実行で追跡対象のファイルが変わりました: ${test_changed}（差分: $run_dir/test-$n.patch）}")
  attempt=$((attempt + 1)) n=$((n + 1))
  prompt=$run_dir/prompt-$n.md
  {
    echo "あなたの実装のあと、サンドボックスの外で次のテストを実行したところ失敗しました（終了コード ${test_status}）。原因を調べて直してください。"
    echo "テストを通すために、テストを消す・弱める・スキップすることはしないでください。テストの期待が要件と食い違っていると判断したら、直さずにその理由を報告してください。進め方と最後の報告の形式は最初の指示と同じです。"
    printf '\n<test-command>\n%s\n</test-command>\n' "$test_cmd"
    printf '\n<test-output>\n（末尾 200 行。全文は %s）\n' "$run_dir/test-$((n - 1)).log"
    tail -n 200 "$run_dir/test-$((n - 1)).log" | cut -c1-500
    printf '</test-output>\n'
  } >"$prompt"
  echo "テストが失敗したので Codex に差し戻します（自動の差し戻し $attempt/$retries 回目）" >&2
done

if ((${#history[@]})); then
  echo "## テストの失敗で自動で差し戻した回"
  echo
  printf -- '- %s\n' "${history[@]}"
  echo
fi
summary
if ((n > first_n)); then
  # 自動で差し戻した回も含めた、この依頼の全体の差分
  git -C "$workdir" diff --binary "$tree_start" "$(snapshot "$workdir" "$excl")" >"$run_dir/diff-$first_n-$n.patch"
  echo "- 差分（自動の差し戻しを含む全体）: $run_dir/diff-$first_n-$n.patch"
fi
[[ -n $dirty && $first_n == 1 ]] && echo "- 注意: 実行前から未コミットの変更がありました。上の差分は Codex が変えた分だけです"
head_now=$(git -C "$workdir" rev-parse HEAD)
[[ $head_now == "$head_start" ]] || echo "- 注意: Codex が HEAD を動かしました（$(git -C "$workdir" rev-parse --short "$head_start") → $(git -C "$workdir" rev-parse --short "$head_now")）"
echo
cat "$run_dir/result-$n.md"
echo
if [[ -n $stat ]]; then printf '\n### 変更ファイル\n\n```\n%s\n```\n' "$stat"; fi
if [[ -n $test_cmd ]] && ((test_status != 0)); then
  echo
  echo "テストが通らないまま、自動の差し戻しの上限（$retries 回）に達しました。出力: $run_dir/test-$n.log"
  exit 3
fi
