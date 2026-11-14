# prepare.sh（implementation-cross-review・design-cross-review・design-alignment-cross-review）が共有する処理。実行せず、source して使う。

# 作業場所のルートの CLAUDE.md・.claude/CLAUDE.md・AGENTS.md を <project-instructions> として出力する。
# サブエージェントは omitClaudeMd で、Codex は project_doc_max_bytes=0 で自動では読まないので、ここで渡す。
print_project_instructions() {
  local source=$1 seen=" " source_real f real sum
  source_real=$(cd -P "$source" && pwd)
  # 同じ内容（CLAUDE.md が AGENTS.md へのリンクのときなど）は 1 回だけ渡す
  for f in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do
    [[ -f $source/$f ]] || continue
    # リンクでリポジトリの外のファイル（秘密情報など）を取り込まないよう、実体がリポジトリの中のものだけを渡す
    real=$(perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); defined $r or exit 1; print $r' "$source/$f") &&
      [[ $real == "$source_real"/* ]] || { echo "注意: $f はリポジトリの外を指しているので渡しません" >&2; continue; }
    sum=$(cksum <"$source/$f" | tr ' ' -)
    [[ $seen != *" $sum "* ]] || continue
    seen+="$sum "
    printf '\n<project-instructions file="%s">\n' "$f"
    cat "$source/$f"
    printf '\n</project-instructions>\n'
  done
}

# snapshot <dir>  作業ツリーの状態（未コミット・未追跡を含む、.gitignore 対象は除く）を、本物のインデックスに
# 触れずにツリーとして記録し、そのツリー ID を出力する。確認のレビューで、前回からの変更だけを取り出すのに使う。
snapshot() {
  local dir=$1 idx real rc=0
  idx=$(mktemp "${TMPDIR:-/tmp}/implementation-cross-review-index.XXXXXX") || return 1
  real=$(git -C "$dir" rev-parse --path-format=absolute --git-path index) || { rm -f "$idx"; return 1; }
  if [[ -f $real ]]; then cp "$real" "$idx" || rc=1; else rm -f "$idx"; fi
  ((rc == 0)) && GIT_INDEX_FILE=$idx git -C "$dir" add -A -- . && GIT_INDEX_FILE=$idx git -C "$dir" write-tree || rc=1
  rm -f "$idx"
  return "$rc"
}

# collect_diff <workdir> <run_dir> <mode> <target>
# レビューする範囲を決め、差分を <run_dir>/diff.patch に書き出す。mode は auto / base / commit / uncommitted。
# 呼び出し元の変数 scope・commits・stat・untracked・source（レビュアーが周辺のコードを読む場所）・sha・files・lines・size を設定する。
# --commit では当時のソースを <run_dir>/tree に展開する。範囲が決まらない・変更がないときはエラーを出して終了する。
collect_diff() {
  local workdir=$1 run_dir=$2 mode=$3 target=$4 from b f rc idx
  g() { git -C "$workdir" "$@"; }
  untracked=() source=$workdir sha=""
  if [[ $mode == commit ]]; then
    sha=$(g rev-parse -q --verify "$target^{commit}") || { echo "エラー: コミット '$target' が見つかりません" >&2; exit 1; }
    scope="コミット $(g log -1 --format='%h %s' "$sha")"
    # コミットメッセージには作成者の説明が入るので、件名だけを渡す
    commits=$(g log -1 --format='%h %s' "$sha")
    # マージコミットは combined diff だと取り込んだ変更が出ないので、第一親との差分にする
    if g rev-parse -q --verify "$sha^1" >/dev/null; then
      stat=$(g diff --stat "$sha^1" "$sha")
      g diff "$sha^1" "$sha" >"$run_dir/diff.patch"
    else
      stat=$(g show --format= --stat "$sha")
      g show --format= --patch "$sha" >"$run_dir/diff.patch"
    fi
    source=$run_dir/tree
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
  if [[ $mode == commit ]]; then
    # HEAD でも未コミットの変更が混ざらないよう、当時のソースを展開する。
    # git archive は export-ignore / export-subst で中身が欠けたり変わったりするので、一時的なインデックスから取り出す
    mkdir -p "$source"
    idx=$(mktemp "${TMPDIR:-/tmp}/implementation-cross-review-index.XXXXXX")
    GIT_INDEX_FILE=$idx g read-tree "$sha"
    GIT_INDEX_FILE=$idx GIT_LFS_SKIP_SMUDGE=1 g checkout-index -a -f --prefix="$source/"
    rm -f "$idx"
  fi
  files=$(grep -c '^diff --git ' "$run_dir/diff.patch" || true)
  lines=$(grep -E '^[+-]' "$run_dir/diff.patch" | grep -cvE '^(\+\+\+|---) ' || true)
  size=$(wc -c <"$run_dir/diff.patch" | tr -d ' ')
}

# collect_fix_diff <workdir> <前回の実行フォルダ> <run_dir>
# 確認のレビュー用に、前回のスナップショット（snapshot.txt・repo.txt・head.txt）から今の作業ツリーまでの差分を
# <run_dir>/fix.patch に書き出す。呼び出し元の変数 scope・commits・files・lines・size を設定する。
# 前回と違う場所・スナップショットがない・rebase やマージを挟んだ・変更がないときは、エラーを出して終了する。
collect_fix_diff() {
  local workdir=$1 prev=$2 run_dir=$3 prev_tree prev_head cur_tree f
  g() { git -C "$workdir" "$@"; }
  for f in snapshot.txt repo.txt head.txt; do
    [[ -s $prev/$f ]] || { echo "エラー: 前回の $f がありません（前回のスナップショットを取れませんでした）。確認のレビューは使えないので、--followup を付けずに全体の差分でレビューしてください" >&2; exit 1; }
  done
  [[ $workdir == "$(cat "$prev/repo.txt")" ]] ||
    { echo "エラー: 前回のリポジトリ（$(cat "$prev/repo.txt")）と違う場所です。--cd を省くか、前回と同じ場所を指定してください" >&2; exit 1; }
  prev_tree=$(cat "$prev/snapshot.txt") prev_head=$(cat "$prev/head.txt")
  g rev-parse -q --verify "$prev_tree^{tree}" >/dev/null ||
    { echo "エラー: 前回のスナップショットが見つかりません（git gc で消えた可能性があります）。確認のレビューは使えないので、--followup を付けずに全体の差分でレビューしてください" >&2; exit 1; }
  # rebase・ブランチの切り替え・マージを挟むと、直したこと以外の変更が差分に入るので止める。
  # fast-forward で入ったコミットは通し、<scope> にコミットの件名を出して、レビュアーが直したことと見分けられるようにする
  g merge-base --is-ancestor "$prev_head" HEAD 2>/dev/null ||
    { echo "エラー: 前回のレビューのあとに rebase かブランチの切り替えがありました。確認のレビューは使えないので、--followup を付けずに全体の差分でレビューしてください" >&2; exit 1; }
  [[ -z $(g rev-list --merges "$prev_head..HEAD") ]] ||
    { echo "エラー: 前回のレビューのあとにマージコミットがあります。確認のレビューは使えないので、--followup を付けずに全体の差分でレビューしてください" >&2; exit 1; }
  cur_tree=$(snapshot "$workdir") || { echo "エラー: 今の作業ツリーのスナップショットを取れませんでした" >&2; exit 1; }
  g diff "$prev_tree" "$cur_tree" >"$run_dir/fix.patch"
  [[ -s $run_dir/fix.patch ]] || { echo "エラー: 前回のレビューから変更がありません" >&2; exit 1; }
  files=$(grep -c '^diff --git ' "$run_dir/fix.patch" || true)
  lines=$(grep -E '^[+-]' "$run_dir/fix.patch" | grep -cvE '^(\+\+\+|---) ' || true)
  size=$(wc -c <"$run_dir/fix.patch" | tr -d ' ')
  scope="確認のレビュー（前回: $(basename "$prev")）"
  commits=$(g log --format='%h %s' "$prev_head..HEAD")
}
