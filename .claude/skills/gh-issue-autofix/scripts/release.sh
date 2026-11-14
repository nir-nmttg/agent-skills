#!/usr/bin/env bash
# Issue の worktree を片付ける。worktree の外（メインの checkout）で実行する。
#   着手（リモートの claude/issue-<番号>）は残す（引数なしの実行で選び直さないように。find-issue.sh の「着手中」の一覧に出る）。
#
# 使い方: release.sh <Issue の番号>
#   worktree に変更がなければ、worktree と、既定ブランチかリモートの claude/issue-<番号> に含まれるローカルのブランチを消す
#   （リモートにあるものは消しても失わない。残すと、人がリモートを rebase したときに start.sh --resume が分岐で止まる）。
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
    die "worktree（${wt}）の中から実行しています。メインの checkout に戻ってから実行してください。"
  elif [[ -n $(git -C "$wt" status --porcelain) ]]; then
    echo "- worktree: 未コミットの変更があるので残した（${wt}）"
    keep_local=true
  else
    # 変更がないことを確かめたので --force で消す（submodule を含む worktree は --force がないと消せない）
    git worktree remove --force "$wt"
    echo "- worktree: 消した（${wt}）"
  fi
fi

# --- ローカルのブランチ（既定ブランチかリモートのブランチに含まれるときだけ消す） ---
if $keep_local; then
  echo "- ローカルの $BRANCH: worktree に変更が残っているので残した"
elif git show-ref -q --verify "$REF"; then
  # リモートの今の sha（追跡の ref ではなく fetch した結果）で判定する
  remote=
  if [[ -n $(remote_sha "$BRANCH") ]]; then
    git fetch -q origin "+$REF:refs/remotes/origin/$BRANCH"
    remote=$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH^{commit}" || true)
  fi
  if git merge-base --is-ancestor "$REF" "origin/$DEFAULT_BRANCH" ||
    { [[ -n $remote ]] && git merge-base --is-ancestor "$REF" "$remote"; }; then
    git branch -q -D "$BRANCH"
    echo "- ローカルの $BRANCH: 消した（既定ブランチかリモートの $BRANCH に含まれる）"
  else
    echo "- ローカルの $BRANCH: どこにもないコミットがあるので残した"
  fi
fi

# --- リモートのブランチ（着手の印） ---
if [[ -n $(remote_sha "$BRANCH") ]]; then
  echo "- リモートの $BRANCH: 着手の印として残した（引数なしの実行では選ばれない）"
else
  echo "- リモートの $BRANCH: なし"
fi
