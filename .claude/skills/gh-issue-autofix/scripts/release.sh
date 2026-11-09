#!/usr/bin/env bash
# Issue の worktree を片付け、作業がなければ着手も取り消す。worktree の外（メインの checkout）で実行する。
#   - コミットせずに止めたとき: 着手（リモートの claude/issue-<番号>）を取り消す
#   - ドラフト PR を作ったあと: worktree だけを消す（PR があるのでブランチは残る）
#
# 使い方: release.sh <Issue の番号>
#   リモートの claude/issue-<番号> に既定ブランチにないコミットがなく、PR もなければ消す。
#   worktree に変更がなければ、worktree と、既定ブランチにないコミットのないローカルのブランチを消す。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

(($# == 1)) || die "使い方: release.sh <Issue の番号>"
NUMBER=$1
require_number "$NUMBER"
require_tools
load_repo

BRANCH=$(branch_name "$NUMBER")
REF="refs/heads/$BRANCH"
fetch_default

# --- worktree（今いる場所や変更のあるものは消さない） ---
wt=$(worktree_of "$BRANCH")
keep_local=false
if [[ -n $wt ]]; then
  if [[ $wt == "$(git rev-parse --show-toplevel)" ]]; then
    die "worktree（$wt）の中から実行しています。メインの checkout に戻ってから実行してください。"
  elif [[ -n $(git -C "$wt" status --porcelain) ]]; then
    echo "- worktree: 未コミットの変更があるので残した（$wt）"
    keep_local=true
  else
    # 変更がないことを確かめたので --force で消す（submodule を含む worktree は --force がないと消せない）
  git worktree remove --force "$wt"
    echo "- worktree: 消した（$wt）"
  fi
fi

# --- ローカルのブランチ ---
if ! $keep_local && git show-ref -q --verify "$REF"; then
  if git merge-base --is-ancestor "$REF" "origin/$DEFAULT_BRANCH"; then
    git branch -q -D "$BRANCH"
    echo "- ローカルの $BRANCH: 消した"
  else
    echo "- ローカルの $BRANCH: origin/$DEFAULT_BRANCH にないコミットがあるので残した"
  fi
fi

# --- リモート ---
if $keep_local; then
  echo "- リモートの $BRANCH: worktree に変更が残っているので残した"
  exit 0
fi
remote=$(remote_sha "$BRANCH")
if [[ -z $remote ]]; then
  echo "- リモートの $BRANCH: なし"
  exit 0
fi
git fetch -q origin "+$REF:refs/remotes/origin/$BRANCH"
prs=$(gh pr list --repo "$REPO" --head "$BRANCH" --state all --json url,isCrossRepository \
  --jq 'map(select(.isCrossRepository | not) | .url) | join(", ")') ||
  die "PR の一覧を取得できません。"
if [[ -n $prs ]]; then
  echo "- リモートの $BRANCH: PR（$prs）があるので残した"
elif ! git merge-base --is-ancestor "$remote" "origin/$DEFAULT_BRANCH"; then
  echo "- リモートの $BRANCH: origin/$DEFAULT_BRANCH にないコミットがあるので残した"
else
  # 確かめた sha のままのときだけ消す
  git push -q --no-verify --force-with-lease="$REF:$remote" origin ":$REF" ||
    die "リモートの $BRANCH を消せません（その間に更新された可能性があります）。"
  git update-ref -d "refs/remotes/origin/$BRANCH" 2>/dev/null || true
  echo "- リモートの $BRANCH: 消した（着手を取り消した）"
fi
