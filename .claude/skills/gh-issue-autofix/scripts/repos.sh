#!/usr/bin/env bash
# 親ディレクトリのモード（Git リポジトリの親ディレクトリで実行したとき）の、モードの判定と対象のリポジトリ（読むだけ）。
#
# 使い方: repos.sh --mode         # repo / parent / error を 1 行で出す
#         repos.sh                # 親ディレクトリの配下（REPO_DEPTH 階層まで）のリポジトリの一覧（機械的な行）
#         repos.sh --find <Issue の URL>   # その Issue のリポジトリの checkout と、組み直した URL を出す
#   --mode:
#     repo   = 今のフォルダが Git の作業ツリーの中（そのリポジトリで手順を行う）
#     parent = 作業ツリーの外で、今のフォルダとその上位に .git がない（ホームと / は除く）
#     error  = .git があるのに git が失敗する、またはホーム・/ で実行した（理由を 2 行目に出す）
#   一覧の行（タブ区切り。親ディレクトリのモードのときだけ）:
#     repo<TAB><パス><TAB><owner/name>   対象（メインの checkout で、origin が GitHub）
#     skip<TAB><パス><TAB><理由>          対象外（報告に書くだけ）
#     dup<TAB><owner/name><TAB><パス>,…   同じリポジトリの checkout が複数ある（どれも対象外にする）
#     fork・権限・push 先の確認は、parent-precheck.sh と、各リポジトリで動くスクリプト（load_repo）が行う。
#   --find: 出力は「- リポジトリ: <パス>」「- 名前: <owner/name>」「- URL: https://github.com/<owner>/<name>/issues/<番号>」。
#     リポジトリのモードでは、origin が合えばメインの checkout を返す。見つからなければ終了コード 2 と理由。
# 終了コード: 0 = 出した、2 = 見つからない・断る（理由を出力）、1 = エラー
set -euo pipefail
DIR=$(cd -P "$(dirname "$0")" && pwd)
source "$DIR/lib.sh"

# 中身を確かめていないフォルダで git を読むときの設定（ローカルの設定のコマンドを動かさない）
gitr() { git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }

mode() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo repo
    return
  fi
  local d
  d=$(pwd -P)
  while :; do
    if [[ -e $d/.git ]]; then
      echo error
      echo "$d に .git がありますが、git がリポジトリとして読めません（safe.directory などを確かめてください）。"
      return
    fi
    [[ $d != / ]] || break
    d=$(dirname "$d")
  done
  d=$(pwd -P)
  if [[ $d == / || $d == "$(cd -P ~ && pwd)" ]]; then
    echo error
    echo "ホームディレクトリや / では、親ディレクトリのモードで動かしません。リポジトリを並べたフォルダで実行してください。"
    return
  fi
  echo parent
}

# 親ディレクトリから何階層下までリポジトリを探すか（例: <親>/<グループ>/<リポジトリ> は 2 階層）
REPO_DEPTH=2

# <フォルダ> の子フォルダのうち、メインの checkout を「<実体のパス><TAB><owner/name>」で、ほかを skip の行で出す。
# Git リポジトリでない実体の子フォルダは、リポジトリをまとめたグループのフォルダとみなし、REPO_DEPTH 階層まで中を探す。
# 依存を置く node_modules は、数が多く対象のリポジトリを含まないので、グループのフォルダとみなさない
walk() {
  local dir=$1 depth=$2 child real top gitdir common super origin repo
  for child in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -d $child ]] || continue
    case $child in
      *$'\t'* | *$'\n'*) printf 'skip\t%s\t%s\n' "（名前にタブか改行を含むフォルダ）" "パスにタブか改行を含む"; continue ;;
    esac
    # シンボリックリンクの実体は、親ディレクトリの中なら本来の場所で調べ、外なら対象外にする（外のリポジトリは報告に書く）
    if [[ -L $child ]]; then
      real=$(cd -P "$child" 2>/dev/null && pwd) || continue
      if [[ $real != "$PARENT"/* && -e $real/.git ]]; then printf 'skip\t%s\t%s\n' "$child" "親ディレクトリの外を指すシンボリックリンク"; fi
      continue
    fi
    # 親ディレクトリの実体のパスから実体のフォルダだけをたどってきたので、$child がそのまま実体のパス
    real=$child
    if [[ ! -e $real/.git ]]; then
      if ((depth < REPO_DEPTH)) && [[ ${child##*/} != node_modules ]]; then walk "$real" $((depth + 1)); fi
      continue
    fi
    top=$(gitr -C "$real" rev-parse --show-toplevel 2>/dev/null) || { printf 'skip\t%s\t%s\n' "$real" "git がリポジトリとして読めない"; continue; }
    top=$(cd -P "$top" && pwd)
    [[ $top == "$real" ]] || continue
    gitdir=$(gitr -C "$real" rev-parse --path-format=absolute --git-dir)
    common=$(gitr -C "$real" rev-parse --path-format=absolute --git-common-dir)
    if [[ $gitdir != "$common" ]]; then printf 'skip\t%s\t%s\n' "$real" "worktree（メインの checkout ではない）"; continue; fi
    super=$(gitr -C "$real" rev-parse --show-superproject-working-tree 2>/dev/null || true)
    if [[ -n $super ]]; then printf 'skip\t%s\t%s\n' "$real" "submodule"; continue; fi
    origin=$(gitr -C "$real" remote get-url origin 2>/dev/null) || { printf 'skip\t%s\t%s\n' "$real" "remote の origin がない"; continue; }
    repo=$(github_repo_of "$origin")
    if [[ -z $repo ]]; then printf 'skip\t%s\t%s\n' "$real" "origin が GitHub ではない"; continue; fi
    printf '%s\t%s\n' "$real" "$repo"
  done
}

list() {
  PARENT=$(pwd -P)
  walk "$PARENT" 1
}

# 一覧を作り、同じ owner/name の checkout をまとめて dup にする
repos() {
  local rows
  rows=$(list)
  # skip の行はそのまま
  grep "^skip"$'\t' <<<"$rows" || true
  # owner/name ごとに数え、1 つなら repo、複数なら dup
  { grep -v "^skip"$'\t' <<<"$rows" || true; } | awk -F'\t' 'NF == 2 { n[$2]++; p[$2] = (p[$2] == "" ? $1 : p[$2] "," $1) }
    END { for (r in n) { if (n[r] == 1) printf "repo\t%s\t%s\n", p[r], r; else printf "dup\t%s\t%s\n", r, p[r] } }' | sort
}

find_repo() {
  local target=$1 lower t_repo number m path row
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$target")
  [[ $lower =~ ^https://(www\.)?github\.com/([^/]+)/([^/]+)/issues/0*([1-9][0-9]*)([/?#].*)?$ ]] ||
    stop "Issue の URL（https://github.com/<owner>/<name>/issues/<番号>）で指定してください: $target"
  t_repo="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}" number=${BASH_REMATCH[4]}
  m=$(mode | head -1)
  case $m in
    repo)
      [[ $(github_repo_of "$(git remote get-url origin 2>/dev/null || true)") == "$t_repo" ]] ||
        stop "今のフォルダのリポジトリと違うリポジトリの Issue です: $target"
      path=$(main_root)
      ;;
    parent)
      row=$(repos | awk -F'\t' -v r="$t_repo" '($1 == "repo" && $3 == r) || ($1 == "dup" && $2 == r)')
      [[ -n $row ]] || stop "$t_repo の checkout が、このフォルダの配下（$REPO_DEPTH 階層まで）にありません。"
      [[ $row == repo* ]] || stop "$t_repo の checkout が複数あります（$(cut -f3 <<<"$row")）。どれで対応するか決められません。"
      path=$(cut -f2 <<<"$row")
      ;;
    *) stop "$(mode | sed -n 2p)" ;;
  esac
  # 照らした大文字小文字のまま組み直す（URL の末尾の任意の文字列を渡さない）
  echo "- リポジトリ: $path"
  echo "- 名前: $t_repo"
  echo "- URL: https://github.com/$t_repo/issues/$number"
}

case ${1:-} in
  --mode)
    (($# == 1)) || die "使い方: repos.sh --mode"
    mode
    ;;
  --find)
    (($# == 2)) || die "使い方: repos.sh --find <Issue の URL>"
    find_repo "$2"
    ;;
  "")
    [[ $(mode | head -1) == parent ]] || die "親ディレクトリのモードではありません（$(mode | tr '\n' ' ')）。"
    repos
    ;;
  *) die "不明な引数: $1" ;;
esac
