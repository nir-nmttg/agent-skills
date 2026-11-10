#!/usr/bin/env bash
# 実行の結果（最後のメッセージの 1 行目）を記録し、通知するかを出す。
#
# 使い方: record-result.sh [--pr <PR の番号>] "<結果の 1 行目>"
#   --pr: Auto-fix で起こされた回。PR ごとに別に記録する（定期実行の 🔧 の重複の抑止に混ざらないように）。
#     前回とまったく同じ 1 行なら通知しない（「取得不完全」などが、起こされるたびに届くのを防ぐ）。
#   「– 対象なし」など – で始まるもの（- や — も同じ扱い）は通知しない。
#   「🔧 <コード>: <説明>」は、前回とコードが同じなら通知しない（直るまで毎時届くのを防ぐ）。
#   ほかは通知する。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

USAGE="使い方: record-result.sh [--pr <PR の番号>] \"<結果の 1 行目>\""
PR=
if [[ ${1:-} == --pr ]]; then
  [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "--pr には PR の番号を指定してください。"
  PR=$2
  shift 2
fi
(($# == 1)) && [[ -n $1 ]] || die "$USAGE"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "git リポジトリの中で実行してください。"
LINE=$1
RECORD=$(state_dir)/last-result${PR:+-pr-$PR}
previous=$(cat "$RECORD" 2>/dev/null || true)
printf '%s\n' "$LINE" >"$RECORD"

if [[ -n $PR && $LINE == "$previous" ]]; then
  echo "通知: しない（この PR の前回と同じ結果）"
  exit 0
fi
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
