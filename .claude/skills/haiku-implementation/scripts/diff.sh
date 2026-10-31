#!/usr/bin/env bash
# Haiku が worktree で変えた分を保存し、変更の概要を出力する。
#
# 使い方: diff.sh <実行フォルダ>
#
# 前回 diff.sh を実行した時点（初回は worktree を切った時点）からの差分を diff-<回>.patch に、
# worktree を切った時点からの全体の差分を diff-all.patch に保存する。リンクした依存フォルダは除く。
set -euo pipefail

usage() { sed -n '4,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
source "$(dirname "$0")/lib.sh"

(($# == 1)) || usage
run_dir=$(cd -P "$1" && pwd)
wt=$run_dir/worktree
[[ -f $run_dir/repo && -d $wt ]] || { echo "エラー: worktree がありません（prepare.sh で準備していないか、反映・破棄済み）" >&2; exit 1; }

n=1
while [[ -e $run_dir/diff-$n.patch ]]; do n=$((n + 1)); done
last=$(<"$run_dir/last-tree") base=$(<"$run_dir/base-tree")
now=$(snapshot "$wt" "$run_dir/linked")
git -C "$wt" diff --binary "$last" "$now" >"$run_dir/diff-$n.patch"
git -C "$wt" diff --binary "$base" "$now" >"$run_dir/diff-all.patch"
echo "$now" >"$run_dir/last-tree"

echo "## Haiku の変更（$n 回目）"
echo
echo "- 変更: $(git -C "$wt" diff --shortstat "$last" "$now" | sed 's/^ *//' | grep . || echo なし)"
echo "- 差分: $run_dir/diff-$n.patch"
((n == 1)) || echo "- 全体の差分（worktree を切った時点から）: $run_dir/diff-all.patch"
head_now=$(git -C "$wt" rev-parse HEAD)
[[ $head_now == "$(<"$run_dir/base-commit")" ]] || echo "- 注意: worktree の HEAD が動いています（$(git -C "$wt" rev-parse --short HEAD)）。Haiku が git の状態を変えた可能性があります"
stat=$(git -C "$wt" diff --stat "$last" "$now")
if [[ -n $stat ]]; then printf '\n```\n%s\n```\n' "$stat"; fi
