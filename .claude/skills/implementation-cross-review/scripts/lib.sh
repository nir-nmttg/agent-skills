# prepare.sh が共有する処理。実行せず、source して使う。

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
