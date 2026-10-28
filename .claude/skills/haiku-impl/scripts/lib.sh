# impl.sh と apply.sh で共有する関数。source して使う。

# snapshot <dir> [<除外するパスの一覧ファイル>]
# 作業ツリーの状態（未コミット・未追跡を含む、.gitignore 対象は除く）を、本物のインデックスに触れずに
# ツリーとして記録し、そのツリー ID を出力する。前後のツリーを比べれば、その間の変更だけを取り出せる。
snapshot() {
  local dir=$1 excl=${2:-} idx real p
  idx=$(mktemp "${TMPDIR:-/tmp}/haiku-impl-index.XXXXXX")
  real=$(git -C "$dir" rev-parse --path-format=absolute --git-path index)
  if [[ -f $real ]]; then cp "$real" "$idx"; else rm -f "$idx"; fi
  GIT_INDEX_FILE=$idx git -C "$dir" add -A -- .
  # 除くパスは追加したあとでインデックスから外す（.gitignore 対象のパスを除外指定すると git add が失敗するため）
  if [[ -n $excl && -s $excl ]]; then
    while IFS= read -r p; do
      GIT_INDEX_FILE=$idx git -C "$dir" rm -r -q --cached --ignore-unmatch -- ":(top,literal)$p" >/dev/null
    done <"$excl"
  fi
  GIT_INDEX_FILE=$idx git -C "$dir" write-tree
  rm -f "$idx"
}
