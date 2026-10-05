#!/usr/bin/env bash
# clone していないリポジトリのコードや PR を GitHub API で読む（読み取り専用）。
#
# 使い方:
#   repo.sh tree   <owner/repo> [正規表現]     # 引数なし: ディレクトリ構成の概要 / あり: パスが一致するファイル一覧
#   repo.sh cat    <owner/repo> <パス> [開始行] [終了行]  # 行番号付きで表示（既定 300 行。ディレクトリなら中身の一覧）
#   repo.sh grep   <owner/repo> <パス> <正規表現>         # ファイル内を行番号付きで検索（前後 2 行つき）
#   repo.sh readme <owner/repo>                           # README
#   repo.sh search <owner/repo> <キーワード>...           # リポジトリ全体のコード検索（path: などの修飾子は使えない）
#   repo.sh log    <owner/repo> [パス]                    # 最近のコミット 15 件（誰がいつ触ったか）
#   repo.sh pr     <owner/repo> <番号>                    # PR の概要・本文・変更ファイル
#   repo.sh prs    <owner/repo> <キーワード>...           # タイトルがキーワードに合う PR（open / closed とも）
set -euo pipefail

usage() { sed -n '4,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

cmd=${1:-} repo=${2:-}
[[ -n $cmd ]] || usage
if [[ ! $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "リポジトリは owner/repo 形式で指定してください。" >&2
  usage
fi
shift 2

# パスを URL 用にエンコードする（/ は残す）
encode_path() {
  [[ $1 != *..* ]] || { echo "パスに .. は使えません。" >&2; exit 1; }
  jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")'
}

# ファイルを $tmp に取得する。バイナリなら知らせて終了する
fetch_file() {
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  gh api "repos/$repo/contents/$(encode_path "$1")" -H "Accept: application/vnd.github.raw" >"$tmp"
  if [[ -s $tmp ]] && ! grep -Iq . "$tmp"; then
    echo "バイナリファイルのため表示しません（$(wc -c <"$tmp" | tr -d ' ') bytes）"
    exit 0
  fi
}

case $cmd in
  tree)
    tree=$(gh api "repos/$repo/git/trees/HEAD?recursive=1")
    if [[ -n ${1:-} ]]; then
      jq -r --arg re "$1" '.tree[] | select(.type == "blob" and (.path | test($re; "i"))) | .path' <<<"$tree" |
        awk 'NR <= 200 { print } END { if (NR > 200) print "…ほか " NR - 200 " 件（正規表現で絞り込んでください）" }'
    else
      # 2 階層目までのディレクトリとファイル数、ルート直下のファイル
      jq -r '
        [.tree[] | select(.type == "blob") | .path] as $files
        | "ファイル数: \($files | length)",
          "",
          "ルート直下のファイル: \([$files[] | select(contains("/") | not)] | join(", "))",
          "",
          "ディレクトリ（2 階層目まで。数字は配下のファイル数）:",
          ( [$files[] | split("/") | .[:-1] | select(length > 0) | (.[:1], select(length > 1) | .[:2]) | join("/")]
            | group_by(.) | map("  \(.[0])/ (\(length))") | .[:150][] )' <<<"$tree"
    fi
    jq -r 'if .truncated then "※ ファイル数が多く一覧が途中で切れています" else empty end' <<<"$tree"
    ;;
  cat)
    [[ -n ${1:-} ]] || usage
    from=${2:-1}
    to=${3:-$((from + 299))}
    [[ $from =~ ^[0-9]+$ && $to =~ ^[0-9]+$ ]] || { echo "開始行・終了行は数字で指定してください。" >&2; exit 1; }
    meta=$(gh api "repos/$repo/contents/$(encode_path "$1")")
    if jq -e 'type == "array"' >/dev/null <<<"$meta"; then
      jq -r '.[] | "\(if .type == "dir" then "📁" else "  " end) \(.path)"' <<<"$meta"
      exit 0
    fi
    fetch_file "$1"
    total=$(awk 'END { print NR }' "$tmp")
    awk -v s="$from" -v e="$to" 'NR >= s && NR <= e { printf "%6d  %s\n", NR, $0 }' "$tmp"
    if ((total > to)); then
      echo "…全 $total 行。続きは: repo.sh cat $repo $1 $((to + 1))"
    fi
    ;;
  grep)
    [[ -n ${1:-} && -n ${2:-} ]] || usage
    fetch_file "$1"
    hits=$(grep -inE -C 2 -- "$2" "$tmp" | sed -E 's/^([0-9]+)[:-]/\1  /' | head -150) || true
    echo "${hits:-ヒットなし}"
    ;;
  readme)
    gh api "repos/$repo/readme" -H "Accept: application/vnd.github.raw" |
      awk 'NR <= 300 { print } END { if (NR > 300) print "…全 " NR " 行（以降省略）" }'
    ;;
  search)
    [[ $# -gt 0 ]] || usage
    # 検索 API は 1 分あたりの回数制限がきついので、ヒットしないときは tree の正規表現で探す
    gh search code "$@" --repo "$repo" --limit 20 --json path,textMatches --jq '
      if length == 0 then "ヒットなし（tree <正規表現> でファイル名から探すのも有効）" else
        .[] | "## \(.path)", (.textMatches[].fragment | split("\n") | map("    " + .) | join("\n")), ""
      end'
    ;;
  log)
    query="per_page=15"
    [[ -z ${1:-} ]] || query+="&path=$(encode_path "$1")"
    gh api "repos/$repo/commits?$query" --jq '
      .[] | "\(.commit.committer.date[0:10])  \(.sha[0:7])  @\(.author.login // .commit.author.name)  \(.commit.message | split("\n")[0])"'
    ;;
  pr)
    [[ ${1:-} =~ ^[0-9]+$ ]] || usage
    gh pr view "$1" --repo "$repo" --json number,title,url,state,author,createdAt,mergedAt,baseRefName,headRefName,body,files --jq '
      "# PR: \(.title)（#\(.number)）",
      "",
      "- URL: \(.url)",
      "- 状態: \(.state) / 作成: @\(.author.login)（\(.createdAt[0:10])）\(if .mergedAt then " / マージ: \(.mergedAt[0:10])" else "" end)",
      "- ブランチ: \(.headRefName) → \(.baseRefName)",
      "",
      "## 本文",
      "",
      "<pr-body>", (if .body == "" then "（本文なし）" else .body end), "</pr-body>",
      "",
      "## 変更ファイル（\(.files | length)件）",
      "",
      (.files[] | "- \(.path)（+\(.additions) -\(.deletions)）")'
    echo
    echo "差分を見るとき: gh pr diff $1 --repo $repo"
    ;;
  prs)
    [[ $# -gt 0 ]] || usage
    # 本文まで検索すると PR テンプレートの定型文に当たってノイズが多いので、タイトルだけを見る
    gh search prs "$@" --repo "$repo" --match title --limit 15 \
      --json number,title,url,state,author,updatedAt,isDraft --jq '
      if length == 0 then "ヒットなし" else
        .[] | "- [#\(.number)](\(.url)) \(.state)\(if .isDraft then "・Draft" else "" end) — \(.title)（@\(.author.login)、更新 \(.updatedAt[0:10])）"
      end'
    ;;
  *)
    usage
    ;;
esac
