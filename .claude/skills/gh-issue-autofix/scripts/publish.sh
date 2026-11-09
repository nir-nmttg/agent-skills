#!/usr/bin/env bash
# 作業ブランチを push し、ドラフト PR を作る（あれば本文を更新する）。worktree の中で実行する。
#
# 使い方: publish.sh <Issue の番号> --title <タイトル> --body-file <本文のファイル | -> [--closes]
#   --body-file - なら本文を標準入力から読む。
#   --closes があれば本文の末尾に「Closes #<番号>」、なければ「Refs #<番号>」を付ける。
#   既存の PR は、このスクリプトが書いたマーカーの範囲だけを置き換える（人が足した部分は残す）。
#   ドラフトでない PR（レビュー中）は更新しない。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

START_MARK='<!-- gh-issue-autofix:start -->'
END_MARK='<!-- gh-issue-autofix:end -->'

NUMBER= TITLE= BODY_FILE= CLOSES=false
while (($#)); do
  case $1 in
    --title | --body-file)
      (($# >= 2)) || die "$1 に値を指定してください。"
      [[ $1 == --title ]] && TITLE=$2 || BODY_FILE=$2
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

fetch_default
(($(git rev-list --count "origin/$DEFAULT_BRANCH..HEAD") > 0)) || die "origin/$DEFAULT_BRANCH にないコミットがありません。"

# fork から同じ名前のブランチで出された PR は除く
pr_json=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json url,isDraft,body,isCrossRepository \
  --jq '[.[] | select(.isCrossRepository | not)][0] // empty') ||
  die "PR の一覧を取得できません。"
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
  # push の間に人が編集したかもしれないので、本文を取り直す。Web で編集された本文は CRLF のことがある
  old=$(gh pr view "$pr" --repo "$REPO" --json body --jq '.body // "" | gsub("\r"; "")') ||
    die "push しましたが、PR（$pr）の本文を取得できません。"
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
