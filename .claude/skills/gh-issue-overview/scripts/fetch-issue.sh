#!/usr/bin/env bash
# Issue の本文・コメント・関連 Issue / PR・リポジトリ概要を取得し、実装計画づくりの材料として出力する。
#
# 使い方: fetch-issue.sh <Issue の URL | owner/repo#番号>
#   例: fetch-issue.sh https://github.com/owner/repo/issues/123
#       fetch-issue.sh owner/repo#123
set -euo pipefail

if ! gh auth status >/dev/null 2>&1; then
  echo "gh が未ログインです。\`gh auth login\` を実行してください。" >&2
  exit 1
fi

owner="" repo="" number=""
for arg in "$@"; do
  if [[ $arg =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([0-9]+) ]] ||
     [[ $arg =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
    owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
    break
  fi
  if [[ $arg =~ github\.com/[^/]+/[^/]+/pull/[0-9]+ ]]; then
    echo "PR の URL です。Issue の URL（.../issues/番号）を指定してください。" >&2
    exit 1
  fi
done
if [[ -z $number ]]; then
  echo "Issue の URL を指定してください（例: https://github.com/owner/repo/issues/123）" >&2
  exit 1
fi

read -r -d '' QUERY <<'GRAPHQL' || true
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    nameWithOwner description url homepageUrl
    primaryLanguage { name }
    languages(first: 6, orderBy: {field: SIZE, direction: DESC}) { nodes { name } }
    repositoryTopics(first: 10) { nodes { topic { name } } }
    defaultBranchRef { name }
    issue(number: $number) {
      number title url state stateReason body createdAt updatedAt
      author { login }
      assignees(first: 10) { nodes { login } }
      labels(first: 20) { nodes { name description } }
      milestone { title dueOn }
      issueType { name }
      parent { ...ref }
      subIssues(first: 50) { totalCount nodes { ...ref } }
      closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { ...ref } }
      comments(first: 100) { totalCount nodes { author { __typename login } createdAt body } }
      timelineItems(first: 100, itemTypes: [CROSS_REFERENCED_EVENT]) {
        nodes { ... on CrossReferencedEvent { source { __typename ...ref } } }
      }
    }
  }
}
fragment ref on IssueOrPullRequest {
  __typename
  ... on Issue { number title url state repository { nameWithOwner } }
  ... on PullRequest { number title url state repository { nameWithOwner } }
}
GRAPHQL

data=$(gh api graphql -f query="$QUERY" -f owner="$owner" -f repo="$repo" -F number="$number")

# 本文・コメントで言及されている Issue / PR（#123, owner/repo#123, URL）を最大 20 件拾う
refs=$(jq -r --arg o "$owner" --arg r "$repo" --argjson n "$number" '
  .data.repository.issue as $i
  | [$i.body, $i.comments.nodes[].body] | join("\n")
  # コード内の #番号 と、リンク文字列 [#1](URL) の #1 は拾わない（URL 側で拾う）
  | gsub("```[\\s\\S]*?```"; "") | gsub("`[^`\n]*`"; "") | gsub("\\[[^\\]\n]*\\]\\("; "(")
  | [ (scan("github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(?:issues|pull)/([0-9]+)")
        | {o: .[0], r: .[1], n: (.[2] | tonumber)}),
      (scan("(?:^|[\\s(\\[])(?:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+))?#([0-9]+)\\b")
        | {o: (.[0] // $o), r: (.[1] // $r), n: (.[2] | tonumber)}) ]
  | map(select([.o, .r, .n] != [$o, $r, $n]))
  # 同じリポジトリのものを先に、番号順で並べる
  | unique_by([.o, .r, .n]) | sort_by([.o != $o or .r != $r, .o, .r, .n]) | .[:20][]
  | "\(.o)\t\(.r)\t\(.n)"' <<<"$data")

mentions='{}'
if [[ -n $refs ]]; then
  q="query {" i=0
  while IFS=$'\t' read -r o r n; do
    q+=" m$i: repository(owner: \"$o\", name: \"$r\") { issueOrPullRequest(number: $n) { ...ref } }"
    i=$((i + 1))
  done <<<"$refs"
  q+=" } fragment ref on IssueOrPullRequest { __typename"
  q+=" ... on Issue { number title url state repository { nameWithOwner }"
  q+="   closedByPullRequestsReferences(first: 3, includeClosedPrs: true) { nodes { number url state } } }"
  q+=" ... on PullRequest { number title url state repository { nameWithOwner } } }"
  # 存在しない番号やアクセスできないリポジトリはエラーになるが、取れた分だけ使う
  mentions=$(gh api graphql -f query="$q" 2>/dev/null || true)
  [[ -n $mentions ]] || mentions='{}'
fi

# Projects のフィールド（ステータス・期限・優先度など）。read:project スコープがなければ省略
projects=$(gh api graphql -F number="$number" -f owner="$owner" -f repo="$repo" -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) { issue(number: $number) { projectItems(first: 5) { nodes {
      project { title }
      fieldValues(first: 20) { nodes {
        ... on ProjectV2ItemFieldSingleSelectValue { v: name field { ... on ProjectV2FieldCommon { name } } }
        ... on ProjectV2ItemFieldDateValue { v: date field { ... on ProjectV2FieldCommon { name } } }
        ... on ProjectV2ItemFieldIterationValue { v: title field { ... on ProjectV2FieldCommon { name } } }
        ... on ProjectV2ItemFieldNumberValue { n: number field { ... on ProjectV2FieldCommon { name } } }
        ... on ProjectV2ItemFieldTextValue { v: text field { ... on ProjectV2FieldCommon { name } } }
      } }
    } } } }
  }' 2>/dev/null || true)
[[ -n $projects ]] || projects='{}'

# いまいるフォルダがこのリポジトリの clone かどうか
local_root=""
if remotes=$(git remote -v 2>/dev/null) &&
   grep -qiE "github\.com[:/]$owner/$repo(\.git)?[[:space:]]" <<<"$remotes"; then
  local_root=$(git rev-parse --show-toplevel)
  local_branch=$(git branch --show-current)
fi

read -r -d '' FORMAT <<'JQ' || true
def date: .[0:10];
def ref: "[\(.repository.nameWithOwner)#\(.number)](\(.url)) \(if .__typename == "PullRequest" then "PR" else "Issue" end)・\(.state) — \(.title)";
def list(f): if length == 0 then "なし" else map(f) | join(", ") end;
# Issue テンプレートや bot が埋め込む HTML コメントは読む必要がないので落とす
def clean: gsub("<!--[\\s\\S]*?-->"; "") | gsub("^\\s+|\\s+$"; "");
def closers: [.closedByPullRequestsReferences.nodes[]? | "[#\(.number)](\(.url)) \(.state)"]
  | if length > 0 then "（閉じた PR: \(join(", "))）" else "" end;
def refs($title): if length == 0 then "- \($title): なし" else "- \($title):", (.[] | "  - \(ref)\(closers)") end;

.[0].data.repository as $repo
| $repo.issue as $i
| .[1].data as $mentions
| .[2].data.repository.issue.projectItems.nodes as $projects
| ($repo.nameWithOwner | split("/")[0] | ascii_downcase) as $org
| "# Issue: \($i.title)（\($repo.nameWithOwner)#\($i.number)）",
  "",
  "- URL: \($i.url)",
  "- 状態: \($i.state)\(if $i.stateReason then "（\($i.stateReason)）" else "" end)\(if $i.issueType then " / 種別: \($i.issueType.name)" else "" end)",
  "- 起票: @\($i.author.login // "ghost")（\($i.createdAt | date)） / 最終更新: \($i.updatedAt | date)",
  "- 担当: \($i.assignees.nodes | list("@\(.login)"))",
  "- ラベル: \($i.labels.nodes | list("`\(.name)`\(if (.description // "") != "" then "（\(.description)）" else "" end)"))",
  "- マイルストーン: \(if $i.milestone then "\($i.milestone.title)\(if $i.milestone.dueOn then "（期限 \($i.milestone.dueOn | date)）" else "" end)" else "なし" end)",
  ( $projects // [] | .[]
    | "- Project「\(.project.title)」: \([.fieldValues.nodes[] | select(.field.name) | "\(.field.name)=\(.v // .n)"] | join(" / "))" ),
  "",
  "## 本文",
  "",
  "<issue-body>",
  ($i.body | clean | if . == "" then "（本文なし）" else . end),
  "</issue-body>",
  "",
  "## コメント（\($i.comments.totalCount)件\(if $i.comments.totalCount > ($i.comments.nodes | length) then "、先頭 \($i.comments.nodes | length) 件のみ" else "" end)）",
  "",
  ( $i.comments.nodes[]
    | (.author.__typename == "Bot") as $bot
    | "<comment author=\"@\(.author.login // "ghost")\" date=\"\(.createdAt | date)\"\(if $bot then " bot" else "" end)>",
      # bot の定型コメントは長くなりがちなので先頭だけ
      (.body | clean | if $bot and length > 300 then .[0:300] + " …（bot のコメントのため省略）" else . end),
      "</comment>",
      "" ),
  "## 関連 Issue / PR",
  "",
  "- 親 Issue: \(if $i.parent then ($i.parent | ref) else "なし" end)",
  ( $i.subIssues.nodes | refs("サブ Issue（\($i.subIssues.totalCount)件）") ),
  ( $i.closedByPullRequestsReferences.nodes | refs("この Issue を閉じる PR") ),
  ( [$mentions // {} | .[] | .issueOrPullRequest // empty] | refs("本文・コメントで言及している Issue / PR") ),
  ( [$i.timelineItems.nodes[].source | select(.repository and (.repository.nameWithOwner | split("/")[0] | ascii_downcase) == $org)]
    | unique_by(.url) | refs("この Issue に言及している Issue / PR（同じ組織のみ）") ),
  "",
  "## リポジトリ",
  "",
  "- \($repo.nameWithOwner): \($repo.description // "（説明なし）")",
  "- 言語: \($repo.languages.nodes | list(.name)) / トピック: \($repo.repositoryTopics.nodes | list(.topic.name))",
  "- デフォルトブランチ: \($repo.defaultBranchRef.name // "-")\(if $repo.homepageUrl and $repo.homepageUrl != "" then " / サイト: \($repo.homepageUrl)" else "" end)"
JQ

printf '%s\n' "$data" "$mentions" "$projects" | jq -rs "$FORMAT"

if [[ -n $local_root ]]; then
  echo "- ローカル: いまのフォルダ（$local_root、ブランチ $local_branch）がこのリポジトリの clone。コードはローカルで調べられる"
else
  echo "- ローカル: いまのフォルダはこのリポジトリではない。コードは repo.sh（GitHub API）で調べる"
fi
