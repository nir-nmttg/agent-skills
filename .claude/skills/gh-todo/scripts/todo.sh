#!/usr/bin/env bash
# 自分宛ての GitHub の仕事（レビュー依頼・返信待ちのメンション・担当 PR / Issue）を取得し、
# Markdown の一覧として出力する。
#
# 使い方: todo.sh [検索修飾子...]
#   例: todo.sh                  # すべて
#       todo.sh org:achromono    # Organization で絞り込み
#       todo.sh repo:owner/name  # リポジトリで絞り込み
set -euo pipefail

# 返信待ちとして拾うメンションの期間（日）
MENTION_DAYS=14

if ! gh auth status >/dev/null 2>&1; then
  echo "gh が未ログインです。\`gh auth login\` を実行してください。" >&2
  exit 1
fi

common="is:open archived:false sort:updated-desc $*"
since=$(date -u -v-"${MENTION_DAYS}"d +%Y-%m-%d 2>/dev/null || date -u -d "${MENTION_DAYS} days ago" +%Y-%m-%d)

read -r -d '' QUERY <<'GRAPHQL' || true
fragment Post on Comment { author { __typename login } body createdAt }

query($issueQ: String!, $prQ: String!, $reviewQ: String!, $mentionQ: String!) {
  viewer { login }
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
  reviews: search(query: $reviewQ, type: ISSUE, first: 50) {
    issueCount
    nodes {
      ... on PullRequest {
        number title url createdAt isDraft additions deletions
        author { login }
        repository { name nameWithOwner }
        reviewRequests(first: 20) {
          nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
        }
        timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20) {
          nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } ... on Team { slug } } } }
        }
        latestReviews(first: 50) { nodes { author { login } } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
  mentions: search(query: $mentionQ, type: ISSUE, first: 30) {
    issueCount
    nodes {
      ... on Issue {
        number title
        repository { name nameWithOwner }
        ...Post url reactionGroups { viewerHasReacted }
        comments(last: 30) { nodes { ...Post url reactionGroups { viewerHasReacted } } }
      }
      ... on PullRequest {
        number title
        repository { name nameWithOwner }
        ...Post url reactionGroups { viewerHasReacted }
        comments(last: 30) { nodes { ...Post url reactionGroups { viewerHasReacted } } }
        reviews(last: 20) { nodes { state ...Post url reactionGroups { viewerHasReacted } } }
        reviewThreads(last: 20) {
          nodes { comments(last: 10) { nodes { state ...Post url reactionGroups { viewerHasReacted } } } }
        }
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

def link: "[#\(.number)](\(.url))";

def ci: {SUCCESS: "CI 🟢", FAILURE: "CI 🔴", ERROR: "CI 🔴", PENDING: "CI 🟡", EXPECTED: "CI 🟡"}[.commits.nodes[0].commit.statusCheckRollup.state // ""] // empty;

def pr_meta: [
  (if .isDraft then "Draft" else empty end),
  ({APPROVED: "✅ 承認済", CHANGES_REQUESTED: "✏️ 修正依頼", REVIEW_REQUIRED: "👀 レビュー待ち"}[.reviewDecision // ""] // empty),
  ci,
  (if .mergeable == "CONFLICTING" then "⚠️ コンフリクト" else empty end)
];

def issue_meta: [
  (.labels.nodes[].name | "`\(.)`"),
  (if .milestone then "🎯 \(.milestone.title)" else empty end)
];

# 個人ではなくチーム経由で依頼されているか
def direct_request($me): any(.reviewRequests.nodes[].requestedReviewer; .login == $me);
def requested_teams: [.reviewRequests.nodes[].requestedReviewer | select(.__typename == "Team") | .slug];

def review_meta($me): [
  (if .isDraft then "Draft" else empty end),
  (if direct_request($me) then empty else (requested_teams[] | "👥 \(.)") end),
  # 依頼が残っているのに自分のレビューがある = 再依頼されている
  (if any(.latestReviews.nodes[]; .author.login == $me) then "🔁 再依頼" else empty end),
  ci,
  "+\(.additions) −\(.deletions)"
];

# 自分（またはチーム）にレビューが依頼された日時。見つからなければ PR の作成日時
def requested_at($me):
  direct_request($me) as $direct
  | requested_teams as $teams
  | .createdAt as $created
  | [.timelineItems.nodes[] | select(.requestedReviewer != null) | select(
      if $direct then .requestedReviewer.login == $me
      else (.requestedReviewer.slug as $s | any($teams[]; . == $s)) end
    ) | .createdAt] | max // $created;

# Issue / PR の本文・コメント・レビュー・レビューコメント（下書きは除く）
def posts:
  ., .comments.nodes[],
  ((.reviews.nodes // [])[] | select(.state != "PENDING")),
  ((.reviewThreads.nodes // [])[] | .comments.nodes[] | select(.state != "PENDING"));

# 期間内に自分をメンションした投稿のうち、その後に自分が投稿しておらず、リアクションもしていないもの（古い順）
def unreplied_mentions($me):
  "(^|[^A-Za-z0-9_-])@\($me)([^A-Za-z0-9_-]|$)" as $re
  | (now - mention_days * 86400 | todate) as $since
  | [posts | {
      who: (.author.login // "ghost"),
      bot: (.author.__typename == "Bot"),
      at: .createdAt,
      body: (.body // ""),
      url,
      reacted: any(.reactionGroups[]?; .viewerHasReacted)
    }] as $posts
  | ([$posts[] | select(.who == $me) | .at] | max // "") as $lastMine
  | [$posts[] | select(
      .who != $me and (.bot | not) and (.reacted | not)
      and .at >= $since and .at > $lastMine
      and (.body | test($re; "i"))
    )] | sort_by(.at);

# メンション本文の冒頭（引用・HTML コメント・自分へのメンションを除く）
def snippet($me):
  gsub("<!--[\\s\\S]*?-->"; "")
  | split("\n") | map(select(test("^\\s*>") | not)) | join(" ")
  | gsub("@\($me)"; ""; "i") | gsub("[`<>]"; "") | gsub("\\s+"; " ") | gsub("^ | $"; "")
  | if length > 40 then .[:40] + "…" else . end;

def item($kind; $at; $cells): {
  kind: $kind,
  org: (.repository.nameWithOwner | split("/")[0]),
  repo: .repository.name,
  at: $at,
  cells: $cells
};

def kinds: [
  {kind: "review", label: "レビュー依頼", title: "🔍 レビュー依頼", cols: ["#", "タイトル", "作成者", "状態", "依頼"]},
  {kind: "mention", label: "要返信", title: "💬 返信待ちのメンション", cols: ["#", "タイトル", "メンション", "日時"]},
  {kind: "pr", label: "担当 PR", title: "🛠️ 担当 PR", cols: ["#", "タイトル", "状態", "更新"]},
  {kind: "issue", label: "担当 Issue", title: "📌 担当 Issue", cols: ["#", "タイトル", "ラベル", "更新"]}
];

# 入力: 同じ組織・同じ種類の項目の配列
def table($k):
  if length == 0 then empty else
    "**\($k.title)**",
    "",
    "| \(["リポジトリ"] + $k.cols | join(" | ")) |",
    "|\([range($k.cols | length + 1) | " --- |"] | join(""))",
    # 最近動きのあるリポジトリから順に並べ、リポジトリ名は各グループの先頭行にだけ出す
    (group_by(.repo)
      | map(sort_by(.at) | reverse) | sort_by(.[0].at) | reverse[]
      | to_entries[]
      | (if .key == 0 then .value.repo else "" end) as $repo
      | "| \([$repo] + .value.cells | join(" | ")) |"),
    ""
  end;

.data as $d
| $d.viewer.login as $me
| [
    ($d.reviews.nodes[] | requested_at($me) as $at
      | item("review"; $at; [link, (.title | cell), "@\(.author.login // "ghost")", (review_meta($me) | join(" · ") | cell), ($at | ago)])),
    ($d.mentions.nodes[] | unreplied_mentions($me) as $m | select($m | length > 0) | $m[-1] as $last
      | item("mention"; $last.at; [link, (.title | cell),
          "[@\($last.who)](\($last.url)) \($last.body | snippet($me) | cell)\(if ($m | length) > 1 then "（ほか \($m | length - 1) 件）" else "" end)",
          ($last.at | ago)])),
    ($d.prs.nodes[] | item("pr"; .updatedAt; [link, (.title | cell), (pr_meta | join(" · ") | cell), (.updatedAt | ago)])),
    ($d.issues.nodes[] | item("issue"; .updatedAt; [link, (.title | cell), (issue_meta | join(" · ") | cell), (.updatedAt | ago)]))
  ] as $all
| ([$d.reviews, $d.mentions, $d.prs, $d.issues] | any(.issueCount > (.nodes | length))) as $truncated
| {review: $d.reviews.issueCount, mention: ($all | map(select(.kind == "mention")) | length), pr: $d.prs.issueCount, issue: $d.issues.issueCount} as $total
| "# 自分宛ての仕事（\(now | strflocaltime("%Y-%m-%d %H:%M")) 時点）",
  "",
  ([kinds[] | "\(.label) \($total[.kind])件\(if .kind == "mention" then "（直近 \(mention_days) 日）" else "" end)"] | join(" · "))
    + (if $truncated then "（件数が多いものは最新分のみ表示）" else "" end),
  "",
  if ($all | length) == 0 then "対応が必要な Issue / PR はありません。" else
    # 最近動きのある組織から順に、区切り線 + 件数付き見出しで区切って並べる
    ($all | group_by(.org) | sort_by(map(.at) | max) | reverse[]
      | . as $items
      | "---",
        "",
        "## 🏢 \(.[0].org)（\([kinds[] as $k | ($items | map(select(.kind == $k.kind)) | length) | select(. > 0) | "\($k.label) \(.)件"] | join(" · "))）",
        "",
        (kinds[] as $k | $items | map(select(.kind == $k.kind)) | table($k)))
  end
JQ

gh api graphql \
  -f query="$QUERY" \
  -f issueQ="is:issue assignee:@me $common" \
  -f prQ="is:pr assignee:@me $common" \
  -f reviewQ="is:pr review-requested:@me $common" \
  -f mentionQ="mentions:@me updated:>=$since $common" \
  --jq "def mention_days: $MENTION_DAYS; $FORMAT"
