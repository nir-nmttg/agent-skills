#!/usr/bin/env bash
# security-audit-verify-items の実行フォルダの作業ツリーを消す（items/ ledger/ issues/ は残す）。
#   cleanup.sh <実行フォルダ>
set -euo pipefail

source "$(dirname "$0")/lib.sh"

[[ $# -eq 1 ]] || { echo "使い方: cleanup.sh <実行フォルダ>" >&2; exit 3; }
root=$(cd -P "$(runs_root)" 2>/dev/null && pwd) || { echo "実行フォルダの置き場所がありません" >&2; exit 1; }
run=$(cd -P "$1" 2>/dev/null && pwd) || { echo "実行フォルダがありません: $1" >&2; exit 1; }
[[ $run == "$root"/* && -f $run/repo ]] || { echo "このスキルの実行フォルダではありません: $1" >&2; exit 1; }
remove_worktree "$run"
echo "removed $run/worktree"
