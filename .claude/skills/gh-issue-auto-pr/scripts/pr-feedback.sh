#!/usr/bin/env bash
# Auto-fix で起こされたときに、PR の状態と、まだ対応していない指摘・CI の失敗・競合を Markdown で出す（読むだけ）。
#
# 使い方: pr-feedback.sh <PR の URL か番号>           # 判定と材料を出す
#         pr-feedback.sh <PR の URL か番号> --begin    # 対応を始めた回数を 1 つ足す（ロックを取ったあと、作業の前）
#         pr-feedback.sh <PR の URL か番号> --limited  # 上限で Auto-fix をオフにしたことを記録する（--list の対象からも外す）
#         pr-feedback.sh <PR の URL か番号> --reset    # 上限の記録を消し、回数を 0 に戻す（人が Auto-fix をオンにし直したとき）
#         pr-feedback.sh <PR の URL か番号> --mark on|off  # Auto-fix をオンにした・オフにしたことを記録する（--list の対象）
#         pr-feedback.sh --list                       # Auto-fix をオンにした open な PR のうち、対応が要りそうなものを出す（定期実行の報告用）
#   判定（「- 判定: 」の行）は次の順で 1 つ:
#     無効（環境変数 GH_ISSUE_AUTO_PR_AUTOFIX が 0 / off）→ 終了（closed・マージ済み）→ 対象外（このスキルの PR でない・
#     ベースが既定ブランチでないなど）→ 取得不完全 → レビュー中（自分の下書きのレビューがある）→ なし → 上限 → あり
#   対応済みの印は、自分（viewer）が書いた、マーカーで始まる書き込み:
#     まとめ  <!-- gh-issue-auto-pr:pr-handled v=1 read-at=<読んだ時刻> result=... answered=... ci-checked=... conflict-checked=... -->
#     返信    <!-- gh-issue-auto-pr:pr-reply v=1 read-at=<読んだ時刻> read=<読んだ最後のコメントの ID> -->
#   読んだ時刻より後に編集された書き込みは、答えたあとでも、もう一度対応する。
#     上限    <!-- gh-issue-auto-pr:pr-limit -->
#   同じアカウントでもマーカーのない書き込みは人のものとして扱う。
#   関係者は、リポジトリに write 以上の権限がある人（bot は除く）。それ以外の書き込みは要件として扱わない。
# 終了コード: 0 = 判定を出した、1 = エラー
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ATTEMPT_LIMIT=5
BODY_LIMIT=2000
# 自分の書き込みの印の先頭に一致する正規表現（改名前の gh-issue-autofix が書いた印も同じものとして読む）
MARK_PREFIX='^<!-- gh-issue-(auto-pr|autofix):'

TARGET= MODE=show MARK=
while (($#)); do
  case $1 in
    --mark)
      [[ ${2:-} == on || ${2:-} == off ]] || die "--mark には on か off を指定してください。"
      MODE=mark; MARK=$2; shift 2
      ;;
    --begin) MODE=begin; shift ;;
    --reset) MODE=reset; shift ;;
    --limited) MODE=limited; shift ;;
    --list) MODE=list; shift ;;
    -*) die "不明なオプション: $1" ;;
    *) [[ -z $TARGET ]] || die "PR は 1 つだけ指定してください。"; TARGET=$1; shift ;;
  esac
done

require_tools
load_repo
OWNER=${REPO%%/*}
NAME=${REPO#*/}

if [[ $MODE == list ]]; then
  [[ -z $TARGET ]] || die "--list には PR を指定しません。"
  # Auto-fix をオンにした記録がある PR だけを見る（未解決で止めたドラフト PR などは、Auto-fix の対象ではない）
  numbers=$(gh pr list --repo "$REPO" --author @me --state open --limit 100 --json number,headRefName,isCrossRepository \
    --jq '.[] | select((.isCrossRepository | not) and (.headRefName | test("^claude/issue-[1-9][0-9]*$"))) | .number') ||
    die "PR の一覧を取得できません。"
  found=0
  for n in $numbers; do
    [[ -f $(state_dir)/pr-$n.autofix ]] || continue
    line=$(GH_ISSUE_AUTO_PR_AUTOFIX=1 GH_ISSUE_AUTO_PR_QUICK=1 bash "$0" "$n" 2>/dev/null | sed -n 's/^- 判定: //p' | head -1) || line="取得できない"
    case ${line:-取得できない} in
      なし* | 終了* | レビュー中*) ;;
      *) echo "- #$n: ${line:-取得できない}"; found=$((found + 1)) ;;
    esac
  done
  ((found > 0)) || echo "- 対応が要りそうな PR: なし"
  exit 0
fi

[[ -n $TARGET ]] || die "PR の URL か番号を指定してください。"
TARGET=${TARGET#\#}
if [[ $TARGET =~ ^[1-9][0-9]*$ ]]; then
  NUMBER=$TARGET
elif [[ $(tr '[:upper:]' '[:lower:]' <<<"$TARGET") =~ ^https://(www\.)?github\.com/([^/]+/[^/]+)/pull/0*([1-9][0-9]*)([/?#].*)?$ ]]; then
  [[ ${BASH_REMATCH[2]} == $(tr '[:upper:]' '[:lower:]' <<<"$REPO") ]] ||
    { echo "- 判定: 対象外（今のフォルダのリポジトリ $REPO の PR ではない）"; exit 0; }
  NUMBER=${BASH_REMATCH[3]}
else
  die "PR の URL か番号を指定してください: $TARGET"
fi

ATTEMPTS_FILE=$(state_dir)/pr-$NUMBER.attempts
attempts=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
[[ $attempts =~ ^[0-9]+$ ]] || attempts=0
case $MODE in
  begin) echo $((attempts + 1)) >"$ATTEMPTS_FILE"; echo "対応の回数: $((attempts + 1)) / $ATTEMPT_LIMIT"; exit 0 ;;
  reset)
    echo 0 >"$ATTEMPTS_FILE"
    rm -f "$(state_dir)/pr-$NUMBER.limited"
    : >"$(state_dir)/pr-$NUMBER.autofix"
    echo "上限の記録を消し、対応の回数を 0 に戻しました。"
    exit 0
    ;;
  limited)
    : >"$(state_dir)/pr-$NUMBER.limited"
    rm -f "$(state_dir)/pr-$NUMBER.autofix"
    echo "上限で Auto-fix をオフにしたことを記録しました。"
    exit 0
    ;;
  mark)
    if [[ $MARK == on ]]; then : >"$(state_dir)/pr-$NUMBER.autofix"; else rm -f "$(state_dir)/pr-$NUMBER.autofix"; fi
    echo "Auto-fix の記録: $MARK"
    exit 0
    ;;
esac

case ${GH_ISSUE_AUTO_PR_AUTOFIX:-} in
  0 | off) echo "- 判定: 無効（環境変数 GH_ISSUE_AUTO_PR_AUTOFIX で無効にしている）"; exit 0 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

graphql() { gh api graphql -F number="$NUMBER" -f owner="$OWNER" -f name="$NAME" "$@"; }

# --- PR の基本情報（mergeable が UNKNOWN なら取り直す） ---
READ_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for try in 1 2 3 4; do
  graphql -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          number url state isDraft baseRefName headRefName headRefOid isCrossRepository mergeable reviewDecision
          author { login }
          autoMergeRequest { enabledAt }
        }
      }
    }' >"$tmp/pr.json" 2>"$tmp/err" || {
    grep -q 'Could not resolve to a PullRequest' "$tmp/err" && { echo "- 判定: 対象外（$REPO に PR #$NUMBER がない）"; exit 0; }
    die "PR #$NUMBER を取得できません。
$(cat "$tmp/err")"
  }
  # --list（GH_ISSUE_AUTO_PR_QUICK）では待たない
  [[ $(jq -r '.data.repository.pullRequest.mergeable' "$tmp/pr.json") == UNKNOWN && $try -lt 4 && -z ${GH_ISSUE_AUTO_PR_QUICK:-} ]] || break
  sleep 5
done

pr() { jq -r ".data.repository.pullRequest.$1" "$tmp/pr.json"; }
VIEWER=$(jq -r .data.viewer.login "$tmp/pr.json")
STATE=$(pr state)
HEAD_REF=$(pr headRefName)
HEAD_OID=$(pr headRefOid)
PR_URL=$(pr url)

case $STATE in
  MERGED | CLOSED) echo "- 判定: 終了（PR は $(tr '[:upper:]' '[:lower:]' <<<"$STATE")）"; exit 0 ;;
esac
if [[ $(pr isCrossRepository) == true || ! $HEAD_REF =~ ^claude/issue-([1-9][0-9]*)$ ]]; then
  echo "- 判定: 対象外（head が同じリポジトリの claude/issue-<番号> ではない）"
  exit 0
fi
ISSUE=${BASH_REMATCH[1]}
[[ $(pr author.login) == "$VIEWER" ]] || { echo "- 判定: 対象外（PR の作成者が自分ではない）"; exit 0; }
[[ $(pr baseRefName) == "$DEFAULT_BRANCH" ]] ||
  { echo "- 判定: 対象外（PR のベースが既定ブランチ $DEFAULT_BRANCH ではない）"; exit 0; }

BASE_OID=$(remote_sha "$DEFAULT_BRANCH")
[[ -n $BASE_OID ]] || die "origin の $DEFAULT_BRANCH の sha を取得できません。"

# --- 接続ごとに全部のページを取る（--paginate が進められるのは 1 つの接続だけなので、クエリを分ける） ---
graphql --paginate -f query='
  query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun { id databaseId name status conclusion }
            ... on StatusContext { id context state }
          }
        } } } } }
      }
    }
  }' >"$tmp/checks.json" || die "PR #$NUMBER のチェックを取得できません。"
graphql --paginate -f query='
  query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviews(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { databaseId state body submittedAt lastEditedAt author { login __typename } }
        }
      }
    }
  }' >"$tmp/reviews.json" || die "PR #$NUMBER のレビューを取得できません。"
graphql --paginate -f query='
  query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 50, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved isOutdated path line
            comments(first: 100) {
              totalCount
              nodes { databaseId body createdAt publishedAt lastEditedAt author { login __typename } pullRequestReview { state } }
            }
          }
        }
      }
    }
  }' >"$tmp/threads.json" || die "PR #$NUMBER のレビューのスレッドを取得できません。"
graphql --paginate -f query='
  query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        comments(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { databaseId body createdAt lastEditedAt author { login __typename } }
        }
      }
    }
  }' >"$tmp/comments.json" || die "PR #$NUMBER のコメントを取得できません。"

# ページを 1 つにまとめる
jq -s '{
  checks_oid: ([.[].data.repository.pullRequest.commits.nodes[0].commit.oid] | first),
  contexts: [.[].data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [] | .[]]
}' "$tmp/checks.json" >"$tmp/checks-all.json"
jq -s '[.[].data.repository.pullRequest.reviews.nodes[]]' "$tmp/reviews.json" >"$tmp/reviews-all.json"
jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]]' "$tmp/threads.json" >"$tmp/threads-all.json"
jq -s '[.[].data.repository.pullRequest.comments.nodes[]]' "$tmp/comments.json" >"$tmp/comments-all.json"

# --- 書いた人の権限（関係者 = write 以上。自分は書き込める） ---
logins=$(jq -r --arg me "$VIEWER" '.[] | (.author // {}) | select(.__typename == "User" and .login != $me) | .login' \
  "$tmp/reviews-all.json" "$tmp/comments-all.json" <(jq '[.[].comments.nodes[]]' "$tmp/threads-all.json") | sort -u)
echo "{\"$VIEWER\": \"admin\"}" >"$tmp/perms.json"
for login in $logins; do
  # 権限がない人は 404 になる。ほかの失敗（認証・レート制限・一時的な障害）は「取得不完全」にする
  if ! perm=$(gh api "repos/$REPO/collaborators/$login/permission" --jq .permission 2>"$tmp/err"); then
    if grep -q 'HTTP 404' "$tmp/err"; then perm=none; else perm=error; fi
  fi
  jq --arg l "$login" --arg p "$perm" '. + {($l): $p}' "$tmp/perms.json" >"$tmp/perms.next" && mv "$tmp/perms.next" "$tmp/perms.json"
done

jq -n \
  --slurpfile pr "$tmp/pr.json" --slurpfile checks "$tmp/checks-all.json" --slurpfile reviews "$tmp/reviews-all.json" \
  --slurpfile threads "$tmp/threads-all.json" --slurpfile comments "$tmp/comments-all.json" --slurpfile perms "$tmp/perms.json" \
  --arg me "$VIEWER" --arg base_oid "$BASE_OID" --arg default "$DEFAULT_BRANCH" --arg issue "$ISSUE" \
  --argjson attempts "$attempts" --argjson limit "$ATTEMPT_LIMIT" --argjson body_limit "$BODY_LIMIT" \
  --arg mark "$MARK_PREFIX" --arg read_at "$READ_AT" \
  --arg repo "$REPO" --arg limited "$([[ -f $(state_dir)/pr-$NUMBER.limited ]] && echo true || echo false)" -f "$(dirname "$0")/pr-feedback.jq" -r
