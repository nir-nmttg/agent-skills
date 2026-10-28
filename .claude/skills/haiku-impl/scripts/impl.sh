#!/usr/bin/env bash
# 会話を共有しない Claude（Haiku 5.5、推論レベル max）に実装させ、Haiku が変えた差分を保存する。
#
# 使い方: impl.sh [--cd <dir>] [--worktree] [--resume <session_id>] [--test <コマンド>] [--test-retries <回数>] <実行フォルダ>
#   --cd        実装するリポジトリ（既定: 今のフォルダ）
#   --worktree  作業フォルダではなく、専用の git worktree（<実行フォルダ>/worktree）で実装させる。
#               並行して何本も動かすときや、その間に Claude が作業フォルダで作業するときに使う。
#               結果は apply.sh で作業フォルダに反映する（2 回目以降は自動で同じ worktree を使う）
#   --resume    前回の Haiku のセッションを再開し、<実行フォルダ>/feedback.md を修正の依頼として渡す
#   --test      Haiku が終わるたびに、サンドボックスの外でこのコマンドを実行する（DB や Docker が要るテスト用）。
#               失敗したら出力を添えて自動で Haiku に差し戻す。2 回目以降の依頼でも同じコマンドを使う
#   --test-retries  テストが失敗したときに自動で差し戻す回数（既定: 2）
#   --resume がなければ <実行フォルダ>/task.md を実装の指示として渡す。
#
# Haiku は claude -p で動かし、次のように制限する。
# - Bash は sandbox で動かす（書き込みは作業場所と一時フォルダだけで .git の中は除く、ネットワークなし）。
#   sandbox が使えなければ起動しない
# - ファイルの操作は作業場所の中だけ（--restricted）。Bash と Edit / Write を許可し、それ以外の操作は確認せずに拒否する（dontAsk）
# - リポジトリの状態を変える git コマンドは拒否する
# - 個人・プロジェクトの設定（許可ルール・hooks）、MCP サーバー、スキルは読み込まない。
#   作業場所のルートの CLAUDE.md・.claude/CLAUDE.md・AGENTS.md は、最初の依頼に入れて渡す
# 結果は回ごとに <実行フォルダ>/result-<回>.md（claude の出力は result-<回>.json）、差分は diff-<回>.patch、
# テストの出力は test-<回>.log に保存する。
# 自動で差し戻した回があれば、この依頼の全体の差分を diff-<最初の回>-<最後の回>.patch にも保存する。
# テストのコマンドは bash -c で、実装している場所（worktree または作業フォルダ）をカレントにして実行する。
# 環境変数 HAIKU_IMPL_WORKDIR（実装している場所）、HAIKU_IMPL_REPO（もとのリポジトリ）、HAIKU_IMPL_RUN_DIR を渡す。
# テストは実行フォルダの親フォルダのロックで 1 本ずつ実行する（並行で動かす Haiku どうしが DB を取り合わないように）。
# テストが通らないまま差し戻しの上限に達したら、終了コード 3 で終わる。
# 環境変数 HAIKU_IMPL_MODEL でモデルを変えられる（既定: claude-haiku-5-5）。
# worktree には、作業フォルダにある依存パッケージのフォルダ（.gitignore 対象の node_modules / .venv / venv /
# .bundle / vendor。HAIKU_IMPL_LINK_DIRS で変えられる）をシンボリックリンクする。
set -euo pipefail

usage() { sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
source "$(dirname "$0")/lib.sh"

workdir=$PWD run_dir="" session="" use_worktree="" test_cmd="" retries=2
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; shift 2 || usage ;;
    --worktree) use_worktree=1; shift ;;
    --resume) session=${2:-}; [[ -n $session ]] || usage; shift 2 ;;
    --test) test_cmd=${2:-}; [[ -n $test_cmd ]] || usage; shift 2 ;;
    --test-retries) retries=${2:-}; [[ $retries =~ ^[0-9]+$ ]] || usage; shift 2 ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

model=${HAIKU_IMPL_MODEL:-claude-haiku-5-5}

command -v claude >/dev/null || { echo "エラー: claude コマンドが見つかりません" >&2; exit 1; }
command -v jq >/dev/null || { echo "エラー: jq コマンドが見つかりません（brew install jq）" >&2; exit 1; }
[[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
input=$run_dir/task.md
[[ -n $session ]] && input=$run_dir/feedback.md
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
[[ -n $session || $n == 1 ]] || { echo "エラー: この実行フォルダは実装済みです。修正の依頼は --resume <session_id> で渡してください" >&2; exit 1; }

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
    base_commit=$(GIT_AUTHOR_NAME=haiku-impl GIT_AUTHOR_EMAIL=haiku-impl@localhost \
      GIT_COMMITTER_NAME=haiku-impl GIT_COMMITTER_EMAIL=haiku-impl@localhost \
      git -C "$repo" commit-tree "$base_tree" -p HEAD -m "haiku-impl base")
    git -C "$repo" -c core.hooksPath=/dev/null worktree add -q --detach "$wt" "$base_commit"
    # 依存パッケージのフォルダをリンクし、Haiku がテストを動かせるようにする（差分からは除く）
    : >"$run_dir/linked"
    link_names=" ${HAIKU_IMPL_LINK_DIRS:-node_modules .venv venv .bundle vendor} "
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

# 許可・拒否のルール。パスの先頭の // は絶対パスを表す。Bash は sandbox の中でしか動かないので丸ごと許可する
# （許可しないと、つないだコマンドなどが dontAsk で拒否される）。拒否のルールは許可より優先される
allowed=(Read Grep Glob Bash "Edit(/$workdir/**)" "Write(/$workdir/**)")
denied=()
for c in commit push stash checkout switch reset rebase merge cherry-pick revert tag worktree clean; do
  denied+=("Bash(git $c)" "Bash(git $c *)")
done
denied+=("Bash(git branch *)")
# 拒否のルールは git -C などですり抜けられるので、sandbox で git の管理ディレクトリ（worktree のものも含む）への書き込みを塞ぐ
git_dir=$(git -C "$workdir" rev-parse --path-format=absolute --git-common-dir)
settings=$(jq -cn --arg git_dir "$git_dir" '{
  sandbox: {enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false, filesystem: {denyWrite: [$git_dir]}},
  disableAllHooks: true
}')
opts=(
  -p
  --model "$model"
  --effort max
  --restricted # 設定ファイルを読まず、ファイルの操作を作業場所に閉じる
  --settings "$settings"
  --tools Read,Grep,Glob,Edit,Write,Bash
  --allowedTools "${allowed[@]}"
  --disallowedTools "${denied[@]}"
  --permission-mode dontAsk
  --permission-prompts none
  --strict-mcp-config
  --disable-slash-commands
  --output-format json
)

# run_haiku  $prompt を Haiku に渡して実装させ、$n 回目の結果と差分を保存する（$session があれば再開）
run_haiku() {
  local tree_before tree_after status=0 out=$run_dir/result-$n.json
  tree_before=$(snapshot "$workdir" "$excl")
  echo "Haiku で実装中（$n 回目）: model=$model effort=max 作業フォルダ=$workdir" >&2
  started=$SECONDS
  (cd "$workdir" && claude "${opts[@]}" ${session:+--resume "$session"}) \
    <"$prompt" >"$out" 2>"$run_dir/claude-$n.log" || status=$?

  # 失敗しても途中までの変更は残るので、差分は必ず保存する
  tree_after=$(snapshot "$workdir" "$excl")
  git -C "$workdir" diff --binary "$tree_before" "$tree_after" >"$run_dir/diff-$n.patch"
  shortstat=$(git -C "$workdir" diff --shortstat "$tree_before" "$tree_after" | sed 's/^ *//')
  stat=$(git -C "$workdir" diff --stat "$tree_before" "$tree_after")

  if ((status != 0)) || ! jq -e '.is_error == false and (.result | type == "string" and length > 0)' "$out" >/dev/null 2>&1; then
    echo "エラー: Haiku の実行に失敗しました（終了コード ${status}）" >&2
    jq -r '.result // empty' "$out" 2>/dev/null | tail -5 >&2 || true
    grep -v 'unrecognized_model' "$run_dir/claude-$n.log" | tail -20 >&2 || true
    if [[ $(jq -r '.api_error_code // empty' "$out" 2>/dev/null) == claude_code_version_too_old ]]; then
      echo "claude CLI（$(command -v claude)、$(claude --version 2>/dev/null)）が古いため、$model を使えません。claude update（Homebrew なら brew upgrade --cask claude-code）で更新してください" >&2
    fi
    [[ -s $run_dir/diff-$n.patch ]] && echo "途中までの変更が $workdir に残っています: ${shortstat}（差分: $run_dir/diff-$n.patch）" >&2
    exit 1
  fi
  jq -r '.result' "$out" >"$run_dir/result-$n.md"

  [[ -n $session ]] || session=$(jq -r '.session_id' "$out")
  tokens=$(jq -r '.usage | "入力 \((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))（うちキャッシュ \(.cache_read_input_tokens // 0)）/ 出力 \(.output_tokens // 0)（うち推論 \(.output_tokens_details.thinking_tokens // 0)）"' "$out" 2>/dev/null || echo 不明)
  denials=$(jq -r '[.permission_denials[]? | .tool_input.command // .tool_input.file_path // .tool_name] | unique | join(", ")' "$out" 2>/dev/null || true)
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
  (cd "$workdir" && HAIKU_IMPL_WORKDIR=$workdir HAIKU_IMPL_REPO=$repo HAIKU_IMPL_RUN_DIR=$run_dir \
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
  echo "## Haiku の実装結果（$n 回目）"
  echo
  echo "- 設定: $model / effort=max"
  if [[ $workdir == "$wt" ]]; then
    echo "- 作業場所: ${wt}（$repo の worktree。反映は apply.sh ${run_dir}）"
  else
    echo "- 作業フォルダ: $workdir"
  fi
  echo "- 変更: ${shortstat:-なし}"
  echo "- 所要時間: $((SECONDS - started)) 秒、トークン: ${tokens:-不明}"
  echo "- 差分: $run_dir/diff-$n.patch"
  echo "- セッション: ${session}（修正の依頼は --resume ${session}）"
  [[ -z $denials ]] || echo "- 拒否された操作: $denials"
  if [[ -n $test_cmd ]]; then
    if ((test_status == 0)); then echo "- テスト: 成功（$test_secs 秒、出力: $run_dir/test-$n.log）"
    else echo "- テスト: 失敗（終了コード $test_status、$test_secs 秒、出力: $run_dir/test-$n.log）"
    fi
    [[ -z $test_changed ]] || echo "- 注意: テストの実行で追跡対象のファイルが変わりました: ${test_changed}（差分: $run_dir/test-$n.patch）"
  fi
}

prompt=$run_dir/prompt-$n.md
if [[ -z $session ]]; then
  {
    cat "$(dirname "$0")/../assets/impl-prompt.md"
    # --restricted では CLAUDE.md などが読み込まれないので、作業場所のルートにあるものを渡す
    # （CLAUDE.md が AGENTS.md へのリンクのときなど、同じ内容は 1 回だけ）
    seen=" "
    for f in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do
      [[ -f $workdir/$f ]] || continue
      sum=$(cksum <"$workdir/$f" | tr ' ' -)
      [[ $seen != *" $sum "* ]] || continue
      seen+="$sum "
      printf '\n## プロジェクトの指示（%s）\n\n' "$f"
      echo "このリポジトリの $f の内容です。指示書と食い違うときは指示書を優先してください。"
      printf '\n<project-instructions file="%s">\n' "$f"
      cat "$workdir/$f"
      printf '\n</project-instructions>\n'
    done
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
  run_haiku
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
  echo "テストが失敗したので Haiku に差し戻します（自動の差し戻し $attempt/$retries 回目）" >&2
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
[[ -n $dirty && $first_n == 1 ]] && echo "- 注意: 実行前から未コミットの変更がありました。上の差分は Haiku が変えた分だけです"
head_now=$(git -C "$workdir" rev-parse HEAD)
[[ $head_now == "$head_start" ]] || echo "- 注意: Haiku が HEAD を動かしました（$(git -C "$workdir" rev-parse --short "$head_start") → $(git -C "$workdir" rev-parse --short "$head_now")）"
echo
cat "$run_dir/result-$n.md"
echo
if [[ -n $stat ]]; then printf '\n### 変更ファイル\n\n```\n%s\n```\n' "$stat"; fi
if [[ -n $test_cmd ]] && ((test_status != 0)); then
  echo
  echo "テストが通らないまま、自動の差し戻しの上限（$retries 回）に達しました。出力: $run_dir/test-$n.log"
  exit 3
fi
