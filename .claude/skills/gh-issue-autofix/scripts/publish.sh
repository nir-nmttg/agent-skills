#!/usr/bin/env bash
# 作業ブランチを push し、ドラフト PR を作る（あれば本文を更新する）。worktree の中で実行する。
#
# 使い方: publish.sh <Issue の番号> --title <タイトル> --body-file <本文のファイル | -> [--closes] [--expect-pr <PR の URL>]
#   --body-file - なら本文を標準入力から読む。
#   --closes があれば本文の末尾に「Closes #<番号>」、なければ「Refs #<番号>」を付ける。
#   --closes がなければ、本文の closing keyword（Fixes #12 など）を Refs に置き換え、
#   push していないコミットのメッセージに closing keyword があれば止める
#   （Issue に PR が紐づくと、find-issue.sh の検索から外れて再開されなくなるため）。
#   --expect-pr: 自動で再開したときに、選んだときにあったドラフト PR を渡す。それが open のドラフトでなければ止める
#   （作業中に人が閉じた・Ready にした PR を、作り直したり更新したりしない）。
#   既存の PR は、このスクリプトが書いたマーカーの範囲だけを置き換える（人が足した部分は残す）。
#   ドラフトでない PR（レビュー中）とマージ済みの PR があれば、push も更新もしない（closed だけなら新しく作る）。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

START_MARK='<!-- gh-issue-autofix:start -->'
END_MARK='<!-- gh-issue-autofix:end -->'
# GitHub が Issue を紐づける closing keyword と、そのあとの Issue の参照（#12・owner/repo#12・Issue の URL）
KEYWORD_RE='\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)(\s*:?\s*)(?=(?:[\w.-]+/[\w.-]+)?#\d|https?://github\.com/[^\s/]+/[^\s/]+/issues/\d)'

NUMBER= TITLE= BODY_FILE= CLOSES=false EXPECT_PR=
while (($#)); do
  case $1 in
    --title | --body-file | --expect-pr)
      (($# >= 2)) || die "$1 に値を指定してください。"
      case $1 in
        --title) TITLE=$2 ;;
        --body-file) BODY_FILE=$2 ;;
        --expect-pr) EXPECT_PR=$2 ;;
      esac
      shift 2
      ;;
    --closes) CLOSES=true; shift ;;
    -*) die "不明なオプション: $1" ;;
    *) [[ -z $NUMBER ]] || die "Issue の番号は 1 つだけ指定してください。"; NUMBER=$1; shift ;;
  esac
done
require_number "$NUMBER"
[[ -n $TITLE ]] || die "--title を指定してください。"
[[ $BODY_FILE == - || -f $BODY_FILE ]] || die "--body-file に本文のファイルか - を指定してください: ${BODY_FILE:-（なし）}"
require_tools
load_repo

BRANCH=$(branch_name "$NUMBER")
current=$(git symbolic-ref -q --short HEAD || true)
[[ $current == "$BRANCH" ]] || die "今のブランチ（${current:-detached HEAD}）が $BRANCH ではありません。worktree の中で実行してください。"
[[ -z $(git status --porcelain) ]] || die "未コミットの変更があります。コミットするか、作業用のファイル（作った .claude/launch.json など）を消してから実行してください。
$(git status --short)"

section=$(mktemp)
body=$(mktemp)
input=$(mktemp)
trap 'rm -f "$section" "$body" "$input"' EXIT
cat -- "$BODY_FILE" >"$input"
[[ -s $input ]] || die "PR の本文が空です。"
if ! $CLOSES; then
  KEYWORD_RE=$KEYWORD_RE perl -CSD -i -pe 's{$ENV{KEYWORD_RE}}{Refs$1}gi' "$input"
fi

fetch_default
(($(git rev-list --count "origin/$DEFAULT_BRANCH..HEAD") > 0)) || die "origin/$DEFAULT_BRANCH にないコミットがありません。"

if ! $CLOSES; then
  # push していないコミットだけを見る（push 済みのものは書き換えられない）
  base="origin/$DEFAULT_BRANCH"
  if [[ -n $(remote_sha "$BRANCH") ]]; then
    git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || die "origin から $BRANCH を取得できません。"
    base="origin/$BRANCH"
  fi
  if git log --format=%B "$base..HEAD" | KEYWORD_RE=$KEYWORD_RE perl -CSD -ne 'BEGIN { $f = 0 } $f = 1 if /$ENV{KEYWORD_RE}/i; END { exit $f }'; then
    :
  else
    die "push していないコミットのメッセージに closing keyword（Fixes #12 など）があります。push の前なので、\`Refs #<番号>\` などに書き換えてから実行し直してください（git commit --amend や git rebase で書き換えてよい）。"
  fi
fi

# fork から同じ名前のブランチで出された PR は除く。状態を問わずに取り、マージ済みがあれば何もしない
prs=$(gh pr list --repo "$REPO" --head "$BRANCH" --state all --limit 100 --json url,state,isDraft,isCrossRepository \
  --jq '[.[] | select(.isCrossRepository | not)]') ||
  die "PR の一覧を取得できません。"
merged=$(jq -r '[.[] | select(.state == "MERGED") | .url] | join(", ")' <<<"$prs")
[[ -z $merged ]] || die "$merged はマージ済みなので、push も PR の作成もしません。"
pr_json=$(jq -c '[.[] | select(.state == "OPEN")][0] // empty' <<<"$prs")
if [[ -n $EXPECT_PR ]]; then
  jq -e --arg u "$EXPECT_PR" 'any(.[]; .url == $u and .state == "OPEN" and .isDraft)' <<<"$prs" >/dev/null ||
    die "$EXPECT_PR が open のドラフトではなくなった（閉じられたか Ready にされた）ので、push も PR の作成もしません。"
fi
if [[ -n $pr_json && $(jq -r .isDraft <<<"$pr_json") != true ]]; then
  die "$(jq -r .url <<<"$pr_json") はドラフトではない（レビュー中）ので、push も更新もしません。"
fi

# force は使わない。リモートが先に進んでいれば失敗する。プロジェクトの pre-push hook も通す
git push -q origin "HEAD:$BRANCH" ||
  die "$BRANCH を push できません（pre-push hook の失敗、リモートの別のコミット、権限・ブランチの保護を確かめてください）。"

{
  echo "$START_MARK"
  cat "$input"
  echo
  if $CLOSES; then echo "Closes #$NUMBER"; else echo "Refs #$NUMBER"; fi
  echo "$END_MARK"
} >"$section"

manual="手動で作るとき: gh pr create --repo $REPO --draft --base $DEFAULT_BRANCH --head $BRANCH --title <タイトル> --body-file <本文のファイル>"

if [[ -z $pr_json ]]; then
  pr=$(gh pr create --repo "$REPO" --draft --base "$DEFAULT_BRANCH" --head "$BRANCH" --title "$TITLE" --body-file "$section") ||
    die "push しましたが、PR を作れません。
$manual"
  echo "ドラフト PR を作りました: $pr"
else
  pr=$(jq -r .url <<<"$pr_json")
  # push の間に人が編集したり、Ready にしたり閉じたりしたかもしれないので、本文と状態を取り直す。Web で編集された本文は CRLF のことがある
  view=$(gh pr view "$pr" --repo "$REPO" --json body,state,isDraft) ||
    die "push しましたが、PR（$pr）の本文を取得できません。"
  [[ $(jq -r '"\(.state) \(.isDraft)"' <<<"$view") == "OPEN true" ]] ||
    die "push しましたが、PR（$pr）がドラフトの open ではなくなったので、本文は更新しません。"
  old=$(jq -r '.body // "" | gsub("\r"; "")' <<<"$view")
  # マーカーが 1 つずつ、start → end の順にあるときだけ差し替える
  marks=$(grep -nxF -e "$START_MARK" -e "$END_MARK" <<<"$old" | cut -d: -f2- | paste -sd'|' - || true)
  if [[ $marks == "$START_MARK|$END_MARK" ]]; then
    # マーカーの範囲だけを差し替える
    awk -v s="$START_MARK" -v e="$END_MARK" -v f="$section" '
      $0 == s { while ((getline line < f) > 0) print line; skip = 1; next }
      $0 == e { skip = 0; next }
      !skip
    ' <<<"$old" >"$body"
  else
    { printf '%s\n\n' "$old"; cat "$section"; } >"$body"
  fi
  # タイトルは人が直しているかもしれないので変えない
  gh pr edit "$pr" --repo "$REPO" --body-file "$body" >/dev/null ||
    die "push しましたが、PR（$pr）の本文を更新できません。"
  echo "既存のドラフト PR を更新しました: $pr"
fi
