#!/usr/bin/env bash
# Issue の worktree を片付ける。worktree の外（メインの checkout）で実行する。
#   着手（リモートの claude/issue-<番号>）は消さずに残す。PR にせずにやめた Issue も、次の引数なしの実行で
#   選び直さないようにする（find-issue.sh の「着手中」の一覧に出る。選び直させるときは人がリモートのブランチを消す）。
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

# --- ローカルのブランチ ---
# リモートの今の sha（追跡の ref ではなく ls-remote）で判定する
remote=
if ! $keep_local; then
  remote=$(remote_sha "$BRANCH")
  if [[ -n $remote ]]; then
    git fetch -q origin "+$REF:refs/remotes/origin/$BRANCH"
    # ls-remote と fetch の間に更新されていたら、fetch した sha を使う（古い sha を根拠にローカルのブランチを消さない）
    remote=$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH^{commit}" || true)
  fi
fi
local_ahead=false
if ! $keep_local && git show-ref -q --verify "$REF"; then
  if git merge-base --is-ancestor "$REF" "origin/$DEFAULT_BRANCH"; then
    git branch -q -D "$BRANCH"
    echo "- ローカルの $BRANCH: 消した"
  elif [[ -n $remote ]] && git merge-base --is-ancestor "$REF" "$remote"; then
    git branch -q -D "$BRANCH"
    echo "- ローカルの $BRANCH: リモートの $BRANCH に含まれるので消した"
  else
    echo "- ローカルの $BRANCH: origin/$DEFAULT_BRANCH にもリモートの $BRANCH にもないコミットがあるので残した"
    local_ahead=true
  fi
fi

# --- リモート ---
if $keep_local; then
  echo "- リモートの $BRANCH: worktree に変更が残っているので残した"
  exit 0
fi
if [[ -z $remote ]]; then
  echo "- リモートの $BRANCH: なし"
  exit 0
fi
if ! git merge-base --is-ancestor "$remote" "origin/$DEFAULT_BRANCH"; then
  echo "- リモートの $BRANCH: origin/$DEFAULT_BRANCH にないコミットがあるので残した（引数なしの実行では選ばれない）"
elif $local_ahead; then
  echo "- リモートの $BRANCH: 着手の印として残した（ローカルにだけあるコミットの続きから再開できる。引数なしの実行では選ばれない）"
else
  echo "- リモートの $BRANCH: 着手の印として残した（引数なしの実行では選ばれない）"
fi
