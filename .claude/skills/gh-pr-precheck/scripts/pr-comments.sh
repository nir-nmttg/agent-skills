#!/usr/bin/env bash
# PR のやり取り（コメント・レビュー・レビュースレッドの全文）を表示する（読み取り専用）。
# 未解決の指摘の全文や、関連 PR が閉じられた理由を読むときに使う。
#
# 使い方: pr-comments.sh <PR の URL | owner/repo#番号>
#   コメントは最新 30 件、レビューは最新 20 件、スレッドは未解決のもの（解決済みは件数だけ）
set -euo pipefail

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

if [[ ${1:-} =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) ]] ||
   [[ ${1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
else
  usage
fi

gh api graphql -F number="$number" -f owner="$owner" -f repo="$repo" -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) { pullRequest(number: $number) {
      number title url state closedAt mergedAt
      comments(last: 30) { totalCount nodes { author { __typename login } createdAt body } }
      reviews(last: 20) { totalCount nodes { author { login } state submittedAt body } }
      reviewThreads(first: 100) { totalCount nodes {
        isResolved isOutdated path line
        comments(first: 20) { nodes { author { login } createdAt body } }
      } }
    } }
  }' --jq '
  def date: .[0:10];
  def clean: gsub("<!--[\\s\\S]*?-->"; "") | gsub("^\\s+|\\s+$"; "");
  .data.repository.pullRequest as $p
  | "# PR のやり取り: \($p.title)（\($p.url)）",
    "",
    "- 状態: \($p.state)\(if $p.mergedAt then "（マージ \($p.mergedAt | date)）" elif $p.closedAt then "（クローズ \($p.closedAt | date)）" else "" end)",
    "",
    "## コメント（\($p.comments.totalCount) 件\(if $p.comments.totalCount > 30 then "、最新 30 件のみ" else "" end)）",
    "",
    ( $p.comments.nodes[]
      | (.author.__typename == "Bot") as $bot
      | "<comment author=\"@\(.author.login // "ghost")\" date=\"\(.createdAt | date)\"\(if $bot then " bot" else "" end)>",
        (.body | clean | if $bot and length > 500 then .[0:500] + " …（bot のコメントのため省略）" else . end),
        "</comment>", "" ),
    "## レビュー（\($p.reviews.totalCount) 件\(if $p.reviews.totalCount > 20 then "、最新 20 件のみ" else "" end)）",
    "",
    ( $p.reviews.nodes[] | select((.body | clean) != "" or .state != "COMMENTED")
      | "<review author=\"@\(.author.login // "ghost")\" state=\"\(.state)\" date=\"\(.submittedAt // "" | date)\">",
        (.body | clean),
        "</review>", "" ),
    ( [$p.reviewThreads.nodes[] | select(.isResolved | not)] as $open
      | "## 未解決のレビュースレッド（\($open | length) 件。解決済み \($p.reviewThreads.totalCount - ($open | length)) 件）",
        "",
        ( $open[]
          | "### `\(.path)\(if .line then ":\(.line)" else "" end)`\(if .isOutdated then "（コードが変わって古くなった）" else "" end)",
            "",
            ( .comments.nodes[]
              | "<comment author=\"@\(.author.login // "ghost")\" date=\"\(.createdAt | date)\">",
                (.body | clean),
                "</comment>", "" ) ) )'
