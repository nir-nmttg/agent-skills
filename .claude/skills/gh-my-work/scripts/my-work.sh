#!/usr/bin/env bash
# 自分にアサインされている open な Issue / PR を取得し、Markdown の一覧として出力する。
#
# 使い方: my-work.sh [検索修飾子...]
#   例: my-work.sh                  # すべて
#       my-work.sh org:achromono    # Organization で絞り込み
#       my-work.sh repo:owner/name  # リポジトリで絞り込み
set -euo pipefail

if ! gh auth status >/dev/null 2>&1; then
  echo "gh が未ログインです。\`gh auth login\` を実行してください。" >&2
  exit 1
fi

base="assignee:@me is:open archived:false sort:updated-desc $*"

read -r -d '' QUERY <<'GRAPHQL' || true
query($issueQ: String!, $prQ: String!) {
  issues: search(query: $issueQ, type: ISSUE, first: 50) {
    issueCount
    nodes {
      ... on Issue {
        number title url updatedAt
        repository { nameWithOwner }
        labels(first: 3) { nodes { name } }
        milestone { title }
      }
    }
  }
  prs: search(query: $prQ, type: ISSUE, first: 50) {
    issueCount
    nodes {
      ... on PullRequest {
        number title url updatedAt isDraft reviewDecision mergeable
        repository { nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}
GRAPHQL

read -r -d '' FORMAT <<'JQ' || true
def ago: ((now - fromdateiso8601) / 86400 | floor) as $d
  | if $d < 1 then "今日更新"
    elif $d < 30 then "\($d)日前更新"
    elif $d < 365 then "\($d / 30 | floor)か月前更新"
    else "\($d / 365 | floor)年前更新" end;

def pr_meta: [
  (if .isDraft then "Draft" else empty end),
  ({APPROVED: "✅ 承認済", CHANGES_REQUESTED: "✏️ 修正依頼", REVIEW_REQUIRED: "👀 レビュー待ち"}[.reviewDecision // ""] // empty),
  ({SUCCESS: "CI 🟢", FAILURE: "CI 🔴", ERROR: "CI 🔴", PENDING: "CI 🟡", EXPECTED: "CI 🟡"}[.commits.nodes[0].commit.statusCheckRollup.state // ""] // empty),
  (if .mergeable == "CONFLICTING" then "⚠️ コンフリクト" else empty end)
];

def issue_meta: [
  (.labels.nodes[].name | "`\(.)`"),
  (if .milestone then "🎯 \(.milestone.title)" else empty end)
];

def section($title; $res; meta):
  "## \($title)（\($res.issueCount)件）",
  "",
  if $res.issueCount == 0 then "なし", "" else
    # 最近動きのあるリポジトリから順に並べる
    ($res.nodes | group_by(.repository.nameWithOwner)
      | map(sort_by(.updatedAt) | reverse) | sort_by(.[0].updatedAt) | reverse[]
      | "**\(.[0].repository.nameWithOwner)**",
        (.[]
          | "- [#\(.number)](\(.url)) \(.title) — \(meta + [.updatedAt | ago] | join(" · "))"),
        ""),
    (($res.issueCount - ($res.nodes | length)) as $rest
      | if $rest > 0 then "…ほか \($rest) 件（表示は最新 50 件まで）", "" else empty end)
  end;

"# 自分の担当（\(now | strflocaltime("%Y-%m-%d %H:%M")) 時点）",
"",
section("Pull Requests"; .data.prs; pr_meta),
section("Issues"; .data.issues; issue_meta)
JQ

gh api graphql \
  -f query="$QUERY" \
  -f issueQ="is:issue $base" \
  -f prQ="is:pr $base" \
  --jq "$FORMAT"
