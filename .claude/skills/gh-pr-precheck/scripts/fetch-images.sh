#!/usr/bin/env bash
# Issue / PR の本文とコメントに貼られた画像（モックアップ・スクリーンショットなど）を取得し、保存先のパスを出力する。
# 非公開リポジトリの画像も、GitHub が本文の HTML に埋め込む期限付きの URL から取得する（gh のトークンは送らない）。
#
# 使い方: fetch-images.sh <Issue / PR の URL | owner/repo#番号>
#   最大 20 枚、1 枚 10MB まで。絵文字の画像は除く
#
# 保存先: このリポジトリ直下の artifacts/gh-pr-precheck/<owner>/<repo>/images/<番号>/（取得のたびに入れ替える）
set -euo pipefail

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

if [[ ${1:-} =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+) ]]; then
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[4]}
elif [[ ${1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
else
  usage
fi

data=$(gh api graphql -F number="$number" -f owner="$owner" -f repo="$repo" -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) { issueOrPullRequest(number: $number) {
      __typename
      ... on Issue { bodyHTML comments(first: 100) { nodes { author { login } createdAt bodyHTML } } }
      ... on PullRequest { bodyHTML comments(first: 100) { nodes { author { login } createdAt bodyHTML } } }
    } }
  }')

# 出典・URL・代替テキストを 1 行ずつ（タブ区切り）
images=$(jq -r '
  .data.repository.issueOrPullRequest as $x
  | ($x.__typename | if . == "PullRequest" then "PR" else "Issue" end) as $kind
  | [ {src: "\($kind) 本文", html: $x.bodyHTML},
      ($x.comments.nodes[] | {src: "\($kind) のコメント @\(.author.login // "ghost")（\(.createdAt[0:10])）", html: .bodyHTML}) ]
  | .[] | .src as $s
  | (.html // "") | [scan("<img[^>]*>")][]
  | select(test("class=\"[^\"]*emoji") | not)
  | (capture("\\ssrc=\"(?<u>[^\"]+)\"") | .u | gsub("&amp;"; "&")) as $u
  | ((capture("\\salt=\"(?<a>[^\"]*)\"") | .a) // "") as $a
  | select($u | startswith("https://"))
  | [$s, $u, $a] | @tsv' <<<"$data" | awk -F'\t' '!seen[$2]++' | head -20)

if [[ -z $images ]]; then
  echo "$owner/$repo#$number の本文・コメントに画像はありません。"
  exit 0
fi

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
dir="$repo_root/artifacts/gh-pr-precheck/$owner/$repo/images/$number"
rm -rf "$dir"
mkdir -p "$dir"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "# $owner/$repo#$number の画像"
echo
i=0
while IFS=$'\t' read -r src url alt; do
  i=$((i + 1))
  name=$(printf '%02d' "$i")
  if ! type=$(curl -sSL --fail --max-time 30 --max-filesize 10485760 -o "$tmp" -w '%{content_type}' "$url" 2>/dev/null); then
    echo "- ⚠️ $name: 取得できませんでした（${src}）"
    continue
  fi
  case ${type%%;*} in
    image/png) ext=png ;;
    image/jpeg) ext=jpg ;;
    image/gif) ext=gif ;;
    image/webp) ext=webp ;;
    image/svg+xml) ext=svg ;;
    *)
      echo "- ⚠️ $name: 画像ではありません（${type:-種類不明}、${src}）"
      continue
      ;;
  esac
  mv "$tmp" "$dir/$name.$ext"
  echo "- $dir/$name.$ext ← $src${alt:+「${alt}」}"
done <<<"$images"
