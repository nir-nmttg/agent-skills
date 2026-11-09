#!/usr/bin/env bash
# 実行の結果（最後のメッセージの 1 行目）を記録し、通知するかを出す。
#
# 使い方: record-result.sh "<結果の 1 行目>"
#   「– 対象なし」など – で始まるもの（- や — も同じ扱い）は通知しない。
#   「🔧 <コード>: <説明>」は、前回とコードが同じなら通知しない（直るまで毎時届くのを防ぐ）。
#   ほかは通知する。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

(($# == 1)) && [[ -n $1 ]] || die "使い方: record-result.sh \"<結果の 1 行目>\""
git rev-parse --show-toplevel >/dev/null 2>&1 || die "git リポジトリの中で実行してください。"
LINE=$1
RECORD=$(state_dir)/last-result
previous=$(cat "$RECORD" 2>/dev/null || true)
printf '%s\n' "$LINE" >"$RECORD"

case $LINE in
  –* | -* | —*) echo "通知: しない（対象なし・何もしなかった）" ;;
  🔧*)
    # 「🔧 <コード>」までで比べる（説明の言い回しは実行ごとに変わりうる）
    if [[ $previous == 🔧* && ${LINE%%:*} == "${previous%%:*}" ]]; then
      echo "通知: しない（前回と同じ設定の問題）"
    else
      echo "通知: する"
    fi
    ;;
  *) echo "通知: する" ;;
esac
