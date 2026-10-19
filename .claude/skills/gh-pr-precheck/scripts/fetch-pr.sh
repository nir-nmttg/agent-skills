#!/usr/bin/env bash
# Issue に対応する PR を見つけ、レビュー前の確認に使う材料（PR の概要・CI・レビュー状況・変更ファイル・コミット・
# プロジェクトの方針が書かれていそうなファイル・Issue と PR に出てくるリンク・ローカルの状態）を出力し、差分を保存する。
#
# 使い方: fetch-pr.sh <Issue の URL | owner/repo#番号> [PR の URL | owner/repo#番号 | 番号]
#   PR を省略すると、今のブランチの PR → Issue を閉じる open な PR → Issue に言及している open な PR の順に探す。
#   候補が複数あるか見つからなければ、候補を表示して終了コード 3 で終わる
#
# 差分の保存先: このリポジトリ直下の artifacts/gh-pr-precheck/<owner>/<repo>/pr-<番号>/<head の SHA 7 桁>.diff
set -euo pipefail

usage() { sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

if ! gh auth status >/dev/null 2>&1; then
  echo "gh が未ログインです。\`gh auth login\` を実行してください。" >&2
  exit 1
fi

issue_arg=${1:-} pr_arg=${2:-}
if [[ $issue_arg =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([0-9]+) ]] ||
   [[ $issue_arg =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
  io=${BASH_REMATCH[1]} ir=${BASH_REMATCH[2]} inum=${BASH_REMATCH[3]}
else
  [[ $issue_arg != *github.com/*/pull/* ]] || echo "1 つ目の引数は Issue の URL（.../issues/番号）にしてください。PR は 2 つ目に指定します。" >&2
  usage
fi

po="" pr="" pnum=""
if [[ -n $pr_arg ]]; then
  if [[ $pr_arg =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) ]] ||
     [[ $pr_arg =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
    po=${BASH_REMATCH[1]} pr=${BASH_REMATCH[2]} pnum=${BASH_REMATCH[3]}
  elif [[ $pr_arg =~ ^#?([0-9]+)$ ]]; then
    po=$io pr=$ir pnum=${BASH_REMATCH[1]}
  else
    echo "PR は URL（.../pull/番号）か owner/repo#番号 で指定してください。" >&2
    exit 1
  fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- 対象の PR を決める ----------------------------------------------------------

how="引数で指定"
if [[ -z $pnum ]]; then
  # 今のブランチの PR。Issue と同じリポジトリか、この Issue を閉じる PR のときだけ使う
  if cur=$(gh pr view --json url,state,closingIssuesReferences 2>/dev/null) &&
     [[ $(jq -r '.state' <<<"$cur") == OPEN ]]; then
    url=$(jq -r '.url' <<<"$cur")
    if [[ $url =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) ]]; then
      co=${BASH_REMATCH[1]} cr=${BASH_REMATCH[2]} cn=${BASH_REMATCH[3]}
      closes=$(jq -r --arg u "https://github.com/$io/$ir/issues/$inum" \
        '[.closingIssuesReferences[]? | select((.url | ascii_downcase) == ($u | ascii_downcase))] | length' <<<"$cur")
      if [[ $(tr '[:upper:]' '[:lower:]' <<<"$co/$cr") == $(tr '[:upper:]' '[:lower:]' <<<"$io/$ir") ]] || ((closes > 0)); then
        po=$co pr=$cr pnum=$cn how="今のブランチの PR"
      fi
    fi
  fi
fi

if [[ -z $pnum ]]; then
  linked=$(gh api graphql -F number="$inum" -f owner="$io" -f repo="$ir" -f query='
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) { issue(number: $number) {
        closedByPullRequestsReferences(first: 10, includeClosedPrs: false) { nodes { ...pr } }
        timelineItems(first: 100, itemTypes: [CROSS_REFERENCED_EVENT]) {
          nodes { ... on CrossReferencedEvent { source { ... on PullRequest { ...pr } } } }
        }
      } }
    }
    fragment pr on PullRequest { number url title state isDraft author { login } repository { nameWithOwner } }')
  candidates=$(jq -c '
    .data.repository.issue as $i
    | ([$i.closedByPullRequestsReferences.nodes[] | select(.state == "OPEN")] | unique_by(.url)) as $closing
    | ([$i.timelineItems.nodes[].source | select(.url and .state == "OPEN")] | unique_by(.url)) as $mentioned
    | if ($closing | length) > 0 then {how: "Issue を閉じる PR", prs: $closing}
      else {how: "Issue に言及している PR", prs: $mentioned} end' <<<"$linked")
  count=$(jq '.prs | length' <<<"$candidates")
  if ((count == 1)); then
    url=$(jq -r '.prs[0].url' <<<"$candidates")
    [[ $url =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) ]]
    po=${BASH_REMATCH[1]} pr=${BASH_REMATCH[2]} pnum=${BASH_REMATCH[3]}
    how=$(jq -r '.how' <<<"$candidates")
  else
    if ((count == 0)); then
      echo "Issue $io/$ir#$inum に対応する open な PR が見つかりません（今のブランチの PR・Issue を閉じる PR・Issue に言及している PR を探しました）。"
    else
      echo "Issue $io/$ir#$inum に対応する PR の候補が $count 件あります（$(jq -r '.how' <<<"$candidates")）。"
      echo
      jq -r '.prs[] | "- [\(.repository.nameWithOwner)#\(.number)](\(.url))\(if .isDraft then "・Draft" else "" end) — \(.title)（@\(.author.login // "ghost")）"' <<<"$candidates"
    fi
    echo
    echo "PR を 2 つ目の引数に指定して実行し直してください: fetch-pr.sh <Issue の URL> <PR の URL>"
    exit 3
  fi
fi

# --- PR の情報を集める -------------------------------------------------------------

gh api graphql -F number="$pnum" -f owner="$po" -f repo="$pr" -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      nameWithOwner
      pullRequest(number: $number) {
        number title url state isDraft body createdAt updatedAt mergedAt
        author { login }
        baseRefName headRefName headRefOid baseRefOid isCrossRepository
        headRepository { nameWithOwner }
        mergeable mergeStateStatus reviewDecision
        additions deletions changedFiles
        labels(first: 20) { nodes { name } }
        assignees(first: 10) { nodes { login } }
        reviewRequests(first: 20) { nodes { requestedReviewer {
          __typename ... on User { login } ... on Team { name } ... on Bot { login } } } }
        latestOpinionatedReviews(first: 20) { nodes { author { login } state submittedAt } }
        reviewThreads(first: 100) { totalCount nodes {
          isResolved isOutdated path line
          comments(first: 1) { nodes { author { login } body } }
        } }
        closingIssuesReferences(first: 10) { nodes { number url } }
        commits(last: 50) { totalCount nodes { commit { abbreviatedOid messageHeadline authoredDate } } }
        last: commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { totalCount nodes {
          __typename
          ... on CheckRun { name status conclusion detailsUrl isRequired(pullRequestNumber: $number) }
          ... on StatusContext { context state targetUrl isRequired(pullRequestNumber: $number) }
        } } } } } }
        comments(last: 30) { totalCount nodes { author { __typename login } createdAt body } }
      }
    }
  }' >"$tmp/pr.json"

if [[ $(jq -r '.data.repository.pullRequest.number // empty' "$tmp/pr.json") == "" ]]; then
  echo "PR $po/$pr#$pnum が見つかりません。" >&2
  exit 1
fi
head_oid=$(jq -r '.data.repository.pullRequest.headRefOid' "$tmp/pr.json")
base_oid=$(jq -r '.data.repository.pullRequest.baseRefOid' "$tmp/pr.json")
head_ref=$(jq -r '.data.repository.pullRequest.headRefName' "$tmp/pr.json")
base_ref=$(jq -r '.data.repository.pullRequest.baseRefName' "$tmp/pr.json")
head_repo=$(jq -r '.data.repository.pullRequest.headRepository.nameWithOwner // empty' "$tmp/pr.json")

gh api --paginate "repos/$po/$pr/pulls/$pnum/files?per_page=100" \
  --jq '.[] | {path: .filename, status, additions, deletions, previous: .previous_filename}' | jq -s . >"$tmp/files.json"

# 方針が書かれていそうなファイルを探すための、PR の head 時点のファイル一覧
gh api "repos/$po/$pr/git/trees/$head_oid?recursive=1" \
  --jq '{truncated, paths: [.tree[] | select(.type == "blob") | .path]}' >"$tmp/tree.json" 2>/dev/null ||
  echo '{"truncated": false, "paths": [], "error": true}' >"$tmp/tree.json"

# リンクを拾うための Issue の本文とコメント
gh api graphql -F number="$inum" -f owner="$io" -f repo="$ir" -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) { issue(number: $number) {
      body comments(first: 100) { nodes { author { __typename login } createdAt body } }
    } }
  }' >"$tmp/issue.json"

# --- 整形して出力する ---------------------------------------------------------------

read -r -d '' FORMAT <<'JQ' || true
def date: .[0:10];
def clean: gsub("<!--[\\s\\S]*?-->"; "") | gsub("\\n\\s*\\n(\\s*\\n)+"; "\n\n") | gsub("^\\s+|\\s+$"; "");
def list(f): if length == 0 then "なし" else map(f) | join(", ") end;
def lockish: test("(^|/)(package-lock\\.json|npm-shrinkwrap\\.json|yarn\\.lock|pnpm-lock\\.yaml|bun\\.lockb?|Gemfile\\.lock|Podfile\\.lock|poetry\\.lock|uv\\.lock|Pipfile\\.lock|Cargo\\.lock|go\\.sum|composer\\.lock|Package\\.resolved|flake\\.lock)$|\\.snap$|(^|/)(dist|generated|__generated__)/|\\.min\\.(js|css)$|\\.pb\\.go$|_pb2\\.pyi?$");
def guideline: test("(^|/)(CLAUDE|AGENTS|GEMINI)\\.md$")
  or test("^\\.claude/rules/.+\\.md$")
  or test("^(\\.github/|docs?/)?(CONTRIBUTING|CODING[_-]?(GUIDELINES?|STANDARDS|CONVENTIONS)|STYLE[_-]?GUIDE|DEVELOPMENT|ARCHITECTURE|CONVENTIONS)(\\.(md|rst|txt|adoc))?$"; "i")
  or test("^\\.github/(PULL_REQUEST_TEMPLATE|pull_request_template)"; "i")
  or test("^\\.github/(copilot-instructions\\.md|instructions/.+)$")
  or test("^\\.cursor/rules/.+") or . == ".cursorrules" or . == ".windsurfrules"
  or test("^docs?/([^/]+/)?[^/]*(guide|convention|style|standard|testing|development|contributing|coding|architecture|policy|policies)[^/]*\\.(md|rst|txt|adoc)$"; "i")
  or test("(^|/)docs?/(adr|adrs|decisions?|architecture[_-]decisions?)/.+"; "i");
def toolconfig: test("^(\\.editorconfig|\\.eslintrc(\\..+)?|eslint\\.config\\.[cm]?[jt]s|\\.prettierrc(\\..+)?|prettier\\.config\\.[cm]?[jt]s|biome\\.jsonc?|\\.rubocop\\.yml|\\.golangci\\.ya?ml|ruff\\.toml|\\.swiftlint\\.yml|\\.stylelintrc(\\..+)?|\\.markdownlint.*|commitlint\\.config\\..+|\\.commitlintrc.*|lefthook\\.ya?ml|\\.pre-commit-config\\.yaml)$");
def failing: IN("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE");
def check: if .__typename == "CheckRun"
  then {name, result: (if .status == "COMPLETED" then .conclusion else "PENDING" end), url: .detailsUrl, required: .isRequired}
  else {name: .context, result: .state, url: .targetUrl, required: .isRequired} end;
def checkline: "  - \(.name)\(if .required then "（必須）" else "" end)\(if .url then " \(.url)" else "" end)";
def comments: .[] | (.author.__typename == "Bot") as $bot
  | "<comment author=\"@\(.author.login // "ghost")\" date=\"\(.createdAt | date)\"\(if $bot then " bot" else "" end)>",
    (.body | clean | if $bot and length > 300 then .[0:300] + " …（bot のコメントのため省略）" else . end),
    "</comment>", "";

.[0].data.repository as $repo
| $repo.pullRequest as $p
| .[1] as $files
| .[2] as $tree
| .[3].data.repository.issue as $issue
| [$files[].path] as $changed
| ($p.last.nodes[0].commit.statusCheckRollup) as $rollup
| ([$rollup.contexts.nodes[]? | check]) as $checks
| ($issue_url | ascii_downcase) as $iu
| "# PR: \($p.title)（\($repo.nameWithOwner)#\($p.number)）",
  "",
  "- URL: \($p.url)",
  "- 選び方: \($how)",
  "- 状態: \($p.state)\(if $p.isDraft then "・Draft" else "" end) / 作成: @\($p.author.login // "ghost")（\($p.createdAt | date)） / 最終更新: \($p.updatedAt | date)\(if $p.mergedAt then " / マージ: \($p.mergedAt | date)" else "" end)",
  "- ブランチ: \(if $p.isCrossRepository then "\($p.headRepository.nameWithOwner // "?"):" else "" end)\($p.headRefName) → \($p.baseRefName)（head \($p.headRefOid[0:7])）",
  "- 規模: \($p.changedFiles) ファイル / +\($p.additions) -\($p.deletions) / コミット \($p.commits.totalCount) 件",
  "- ラベル: \($p.labels.nodes | list("`\(.name)`")) / 担当: \($p.assignees.nodes | list("@\(.login)"))",
  "",
  "## レビューに出せる状態か",
  "",
  "- Issue との紐づけ: \(if [$p.closingIssuesReferences.nodes[] | select((.url | ascii_downcase) == $iu)] | length > 0
      then "✅ マージで Issue が閉じる（Closes などで紐づけ済み）"
      else "⚠️ この PR はマージしても Issue を閉じない（Closes などの紐づけがない。閉じる Issue: \($p.closingIssuesReferences.nodes | list("\(.url)"))）" end)",
  ( if $rollup == null then "- CI: チェックなし（1 つも実行されていない）"
    else
      ([$checks[] | select(.result | failing)]) as $ng
      | ([$checks[] | select(.result | IN("PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "EXPECTED"))]) as $wait
      | "- CI: \(if ($ng | length) > 0 then "🔴 失敗あり" elif ($wait | length) > 0 then "🟡 実行中" else "🟢 成功" end)（\($checks | length) 件中 失敗 \($ng | length)・実行中 \($wait | length)）",
        (if ($ng | length) > 0 then "  - 失敗:", ($ng[] | checkline) else empty end),
        (if ($wait | length) > 0 then "  - 実行中・待ち:", ($wait[] | checkline) else empty end)
    end ),
  "- マージ: \({"MERGEABLE": "コンフリクトなし", "CONFLICTING": "⚠️ コンフリクトあり", "UNKNOWN": "判定中"}[$p.mergeable] // $p.mergeable) / \({"CLEAN": "マージできる", "BEHIND": "ベースブランチより古い（取り込みが必要）", "BLOCKED": "ブランチ保護の条件を満たしていない（レビュー・必須チェックなど）", "DIRTY": "コンフリクトあり", "DRAFT": "Draft", "UNSTABLE": "必須でないチェックが失敗・実行中", "HAS_HOOKS": "マージできる（フックあり）", "UNKNOWN": "判定中"}[$p.mergeStateStatus] // $p.mergeStateStatus)",
  "- レビュー: \({"APPROVED": "承認済み", "CHANGES_REQUESTED": "修正依頼あり", "REVIEW_REQUIRED": "レビュー待ち"}[$p.reviewDecision // ""] // "必須レビューの設定なし") / 依頼中: \($p.reviewRequests.nodes | list(.requestedReviewer | if . == null then "（見えないレビュアー）" elif .__typename == "Team" then "@\(.name)（チーム）" else "@\(.login // "?")" end)) / レビュー済み: \($p.latestOpinionatedReviews.nodes | list("@\(.author.login // "ghost") \(.state)"))",
  ( [$p.reviewThreads.nodes[] | select(.isResolved | not)] as $open
    | "- 未解決のレビュースレッド: \($open | length) 件\(if ([$open[] | select(.isOutdated)] | length) > 0 then "（うちコードが変わって古くなったもの \([$open[] | select(.isOutdated)] | length) 件）" else "" end)",
      ($open[:20][] | "  - `\(.path)\(if .line then ":\(.line)" else "" end)`\(if .isOutdated then "（古い）" else "" end) @\(.comments.nodes[0].author.login // "ghost")「\(.comments.nodes[0].body | gsub("\\s+"; " ") | if length > 300 then .[0:300] + "…" else . end)」"),
      (if ($open | length) > 0 then "  - 全文・返信は pr-comments.sh で読める" else empty end) ),
  "",
  "## 本文",
  "",
  "<pr-body>",
  ($p.body | clean | if . == "" then "（本文なし）" else . end),
  "</pr-body>",
  "",
  "## 変更ファイル（\($files | length) 件）",
  "",
  ( $files[:300][] | "- \(.path)（\(.status) +\(.additions) -\(.deletions)）\(if .previous then " ← \(.previous)" else "" end)\(if .path | lockish then "（ロック・生成物）" else "" end)" ),
  ( if ($files | length) > 300 then "- …ほか \(($files | length) - 300) 件" else empty end ),
  "",
  "## コミット（\($p.commits.totalCount) 件\(if $p.commits.totalCount > 50 then "、最新 50 件のみ" else "" end)）",
  "",
  ( $p.commits.nodes[] | "- \(.commit.abbreviatedOid) \(.commit.messageHeadline)（\(.commit.authoredDate | date)）" ),
  "",
  "## PR のコメント（\($p.comments.totalCount) 件\(if $p.comments.totalCount > 30 then "、最新 30 件のみ" else "" end)）",
  "",
  ( $p.comments.nodes | comments ),
  "## プロジェクトの方針が書かれていそうなファイル（PR の head 時点）",
  "",
  ( if $tree.error then "- ファイル一覧を取得できませんでした（repo.sh tree で探す）"
    else
      # サブフォルダの CLAUDE.md / AGENTS.md は、変更したファイルがその下にあるものだけ
      ([$tree.paths[] | select(guideline)
        | select(if test("(^|/)(CLAUDE|AGENTS|GEMINI)\\.md$")
            then (split("/") | .[:-1] | join("/")) as $d | ($d == "" or any($changed[]; startswith($d + "/")))
            else true end)]) as $g
      | ([$tree.paths[] | select(toolconfig)]) as $c
      | "- 規約・ガイド:\(if ($g | length) == 0 then " なし" else "" end)",
        ($g[:40][] | "  - \(.)"),
        (if ($g | length) > 40 then "  - …ほか \(($g | length) - 40) 件" else empty end),
        "- ツールの設定（リポジトリ直下）: \($c | list("`\(.)`"))",
        (if $tree.truncated then "- ※ ファイル数が多く一覧が途中で切れています" else empty end)
    end ),
  "",
  "## Issue と PR に出てくるリンク（GitHub の Issue / PR 以外）",
  "",
  ( [ {src: "Issue 本文", body: $issue.body},
      ($issue.comments.nodes[] | select(.author.__typename != "Bot") | {src: "Issue のコメント @\(.author.login // "ghost")（\(.createdAt | date)）", body}),
      {src: "PR 本文", body: $p.body},
      ($p.comments.nodes[] | select(.author.__typename != "Bot") | {src: "PR のコメント @\(.author.login // "ghost")（\(.createdAt | date)）", body}) ]
    | [ .[] | .src as $s | (.body // "" | clean) | [scan("https?://[^\\s<>()\\[\\]\"'`]+")][] | sub("[.,;:!?]+$"; "") | {url: ., src: $s} ]
    | ([.[] | select(.url | test("^https://(github\\.com/user-attachments/|user-images\\.githubusercontent\\.com/|private-user-images\\.githubusercontent\\.com/)"))]) as $att
    | ([.[] | select(.url | test("^https://(github\\.com/user-attachments/|user-images\\.githubusercontent\\.com/|private-user-images\\.githubusercontent\\.com/)|^https://github\\.com/[^/]+/[^/]+/(issues|pull)/[0-9]+|^https://api\\.github\\.com/|^https://github\\.com/[^/]+/[^/]+/(labels|milestones?)(/|$)") | not)]
       | group_by(.url) | map({url: .[0].url, src: ([.[].src] | unique | join("・"))})) as $all
    | ([$all[] | select(.url | test("^https://github\\.com/[^/]+/[^/]+/(blob|tree|commit)/"))]) as $code
    | ([$all[] | select(.url | test("^https://github\\.com/[^/]+/[^/]+/(blob|tree|commit)/") | not)]) as $links
    | (if ($links | length) == 0 then "- 資料などのリンク: なし" else "- 資料などのリンク:", ($links[:40][] | "  - \(.url)（\(.src)）") end),
      (if ($links | length) > 40 then "  - …ほか \(($links | length) - 40) 件" else empty end),
      (if ($code | length) == 0 then empty else "- コードへのリンク（WebFetch ではなく pr-file.sh / repo.sh で読む）: \($code | length) 件", ($code[:20][] | "  - \(.url)（\(.src)）") end),
      "- 添付（画像など）: \(if ($att | length) == 0 then "なし" else "\($att | unique_by(.url) | length) 件（\($att | group_by(.src) | map("\(.[0].src) \(length)") | join("・"))）。画像を見るときは fetch-images.sh" end)" )
JQ

jq -rs --arg how "$how" --arg issue_url "https://github.com/$io/$ir/issues/$inum" "$FORMAT" \
  "$tmp/pr.json" "$tmp/files.json" "$tmp/tree.json" "$tmp/issue.json"

# --- 差分を保存する ---------------------------------------------------------------

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
dir="$repo_root/artifacts/gh-pr-precheck/$po/$pr/pr-$pnum"
mkdir -p "$dir"
diff_file="$dir/${head_oid:0:7}.diff"

echo
echo "## 差分"
echo
if gh pr diff "$pnum" --repo "$po/$pr" >"$diff_file" 2>"$tmp/diff.err"; then
  echo "- 保存: ${diff_file}（$(awk 'END { print NR }' "$diff_file") 行）"
elif git cat-file -e "$base_oid^{commit}" 2>/dev/null && git cat-file -e "$head_oid^{commit}" 2>/dev/null &&
     git diff "$base_oid...$head_oid" >"$diff_file"; then
  echo "- 保存: ${diff_file}（$(awk 'END { print NR }' "$diff_file") 行。GitHub から取れなかったためローカルの git で作成）"
else
  rm -f "$diff_file"
  echo "- ⚠️ 差分を取得できませんでした: $(head -1 "$tmp/diff.err")"
  echo "  - ファイルごとの差分: \`gh api repos/$po/$pr/pulls/$pnum/files --paginate --jq '.[] | .filename, .patch'\`"
fi

# --- ローカルの状態 -----------------------------------------------------------------

echo
echo "## ローカル"
echo
match="$po/$pr"
[[ -z $head_repo ]] || match="($po/$pr|$head_repo)"
if remotes=$(git remote -v 2>/dev/null) && grep -qiE "github\.com[:/]$match(\.git)?[[:space:]]" <<<"$remotes"; then
  root=$(git rev-parse --show-toplevel)
  branch=$(git branch --show-current)
  head=$(git rev-parse HEAD)
  dirty=$(git status --porcelain | awk 'END { print NR }')
  echo "- いまのフォルダ（${root}、ブランチ ${branch:-（detached）}）はこのリポジトリの clone"
  if [[ $head == "$head_oid" ]]; then
    echo "- HEAD が PR の head と一致。PR のコードはローカルで Read / Grep できる"
    ((dirty == 0)) || echo "- ⚠️ 未コミットの変更が $dirty 件ある（PR には含まれていない）"
  elif git cat-file -e "$head_oid^{commit}" 2>/dev/null; then
    ahead=$(git rev-list --count "$head_oid..HEAD")
    behind=$(git rev-list --count "HEAD..$head_oid")
    if [[ $branch == "$head_ref" ]]; then
      echo "- ⚠️ PR のブランチだが HEAD が PR の head と違う（未プッシュ $ahead コミット / PR 側が $behind コミット先）"
      ((dirty == 0)) || echo "- ⚠️ 未コミットの変更が $dirty 件ある（PR には含まれていない）"
    else
      echo "- いまのブランチは PR のブランチではない"
    fi
    echo "- PR の head のファイルは \`git show $head_oid:<パス>\`、ベースは \`git show origin/$base_ref:<パス>\` で読める"
  else
    echo "- PR の head（${head_oid:0:7}）はローカルにない。PR のファイルは pr-file.sh、ベースは \`git show origin/$base_ref:<パス>\` で読む"
  fi
else
  echo "- いまのフォルダはこのリポジトリの clone ではない。PR のファイルは pr-file.sh（ref は ${head_oid}）、ベースブランチのコードは repo.sh で読む"
fi
