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
        repository { name nameWithOwner }
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
        repository { name nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}
GRAPHQL

read -r -d '' FORMAT <<'JQ' || true
def ago: ((now - fromdateiso8601) / 86400 | floor) as $d
  | if $d < 1 then "今日"
    elif $d < 30 then "\($d)日前"
    elif $d < 365 then "\($d / 30 | floor)か月前"
    else "\($d / 365 | floor)年前" end;

# 表のセル内で | が列区切りと解釈されないようにする
def cell: gsub("\\|"; "\\|");

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

# 入力: 同じ組織の Issue または PR の配列
def table($title; $metaCol; meta):
  if length == 0 then empty else
    "**\($title)**",
    "",
    "| リポジトリ | # | タイトル | \($metaCol) | 更新 |",
    "| --- | --- | --- | --- | --- |",
    # 最近動きのあるリポジトリから順に並べ、リポジトリ名は各グループの先頭行にだけ出す
    (group_by(.repository.name)
      | map(sort_by(.updatedAt) | reverse) | sort_by(.[0].updatedAt) | reverse[]
      | to_entries[]
      | (if .key == 0 then .value.repository.name else "" end) as $repo
      | .value
      | "| \($repo) | [#\(.number)](\(.url)) | \(.title | cell) | \(meta | join(" · ") | cell) | \(.updatedAt | ago) |"),
    ""
  end;

.data as $d
| ([$d.prs.nodes[] | .kind = "pr"] + [$d.issues.nodes[] | .kind = "issue"]
   | map(.org = (.repository.nameWithOwner | split("/")[0]))) as $all
| (($d.prs.issueCount > ($d.prs.nodes | length)) or ($d.issues.issueCount > ($d.issues.nodes | length))) as $truncated
| "# 自分の担当（\(now | strflocaltime("%Y-%m-%d %H:%M")) 時点）",
  "",
  "PR \($d.prs.issueCount)件 · Issue \($d.issues.issueCount)件\(if $truncated then "（それぞれ最新 50 件まで表示）" else "" end)",
  "",
  if ($all | length) == 0 then "担当中の Issue / PR はありません。" else
    # 最近動きのある組織から順に、区切り線 + 件数付き見出しで区切って並べる
    ($all | group_by(.org) | sort_by(map(.updatedAt) | max) | reverse[]
      | map(select(.kind == "pr")) as $prs
      | map(select(.kind == "issue")) as $issues
      | "---",
        "",
        "## 🏢 \(.[0].org)（\([
          ($prs | length | select(. > 0) | "PR \(.)件"),
          ($issues | length | select(. > 0) | "Issue \(.)件")
        ] | join(" · "))）",
        "",
        ($prs | table("Pull Requests"; "状態"; pr_meta)),
        ($issues | table("Issues"; "ラベル"; issue_meta)))
  end
JQ

gh api graphql \
  -f query="$QUERY" \
  -f issueQ="is:issue $base" \
  -f prQ="is:pr $base" \
  --jq "$FORMAT"
