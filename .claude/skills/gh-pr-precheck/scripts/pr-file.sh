#!/usr/bin/env bash
# PR の head（または任意のコミット）時点のファイルを GitHub API で読み、行番号付きで表示する（読み取り専用）。
#
# 使い方: pr-file.sh <owner/repo> <コミット SHA | ブランチ> <パス> [開始行] [終了行]
#   既定 300 行。ディレクトリなら中身の一覧を表示する
set -euo pipefail

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

(($# >= 3)) || usage
repo=$1 ref=$2 path=$3
from=${4:-1}
to=${5:-$((from + 299))}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "リポジトリは owner/repo 形式で指定してください。" >&2; usage; }
[[ $ref =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "ref に使えない文字が含まれています。" >&2; exit 1; }
[[ $path != *..* ]] || { echo "パスに .. は使えません。" >&2; exit 1; }
[[ $from =~ ^[0-9]+$ && $to =~ ^[0-9]+$ ]] || { echo "開始行・終了行は数字で指定してください。" >&2; exit 1; }

encoded=$(jq -rn --arg p "$path" '$p | split("/") | map(@uri) | join("/")')
ref_q=$(jq -rn --arg r "$ref" '$r | @uri')

meta=$(gh api "repos/$repo/contents/$encoded?ref=$ref_q")
if jq -e 'type == "array"' >/dev/null <<<"$meta"; then
  jq -r '.[] | "\(if .type == "dir" then "📁" else "  " end) \(.path)"' <<<"$meta"
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
gh api "repos/$repo/contents/$encoded?ref=$ref_q" -H "Accept: application/vnd.github.raw" >"$tmp"
if [[ -s $tmp ]] && ! grep -Iq . "$tmp"; then
  echo "バイナリファイルのため表示しません（$(wc -c <"$tmp" | tr -d ' ') bytes）"
  exit 0
fi

total=$(awk 'END { print NR }' "$tmp")
awk -v s="$from" -v e="$to" 'NR >= s && NR <= e { printf "%6d  %s\n", NR, $0 }' "$tmp"
if ((total > to)); then
  echo "…全 $total 行。続きは: pr-file.sh $repo $ref $path $((to + 1))"
fi
