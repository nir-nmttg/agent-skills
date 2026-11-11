#!/usr/bin/env bash
# 実行の結果（最後のメッセージの 1 行目）を記録し、通知するかを出す。
#
# 使い方: record-result.sh [--pr <PR の番号>] "<結果の 1 行目>"
#         record-result.sh --parent <親ディレクトリ> [--repo <owner/name> | --clear-delegated] "<結果の 1 行目>"
#   --pr: Auto-fix で起こされた回。PR ごとに別に記録する（定期実行の 🔧 の重複の抑止に混ざらないように）。
#     前回とまったく同じ 1 行なら通知しない（「取得不完全」などが、起こされるたびに届くのを防ぐ）。
#   --parent: 親ディレクトリのモードの記録（lib.sh の parent_state_dir）に書く。git の確認と state_dir は通らない。
#     --repo: 親ディレクトリのモードの確認が見つけた、そのリポジトリの問題の記録（リポジトリの .git の記録は子のセッションだけが書く）。
#     --clear-delegated: parent-precheck.sh が書いた起動の予約を消す（子のセッションを起動できなかったとき）。
#   「– 対象なし」など – で始まるもの（- や — も同じ扱い）は通知しない。
#   「🔧 <コード>: <説明>」は、前回とコードが同じなら通知しない（直るまで毎時届くのを防ぐ）。
#   ほかは通知する。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

USAGE="使い方: record-result.sh [--pr <PR の番号>] \"<結果の 1 行目>\" / record-result.sh --parent <親ディレクトリ> [--repo <owner/name> | --clear-delegated] \"<結果の 1 行目>\""
PR= PARENT= REPO= CLEAR=false
while (($# > 1)); do
  case $1 in
    --pr)
      [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "--pr には PR の番号を指定してください。"
      PR=$2
      shift 2
      ;;
    --parent)
      [[ -n ${2:-} ]] || die "$USAGE"
      PARENT=$2
      shift 2
      ;;
    --repo)
      [[ ${2:-} =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "--repo には owner/name を指定してください。"
      REPO=$2
      shift 2
      ;;
    --clear-delegated)
      CLEAR=true
      shift
      ;;
    *) break ;;
  esac
done
(($# == 1)) && [[ -n $1 ]] || die "$USAGE"
LINE=$1
if [[ -n $PARENT ]]; then
  [[ -z $PR ]] || die "--pr と --parent は一緒に使えません。"
  [[ -z $REPO ]] || ! $CLEAR || die "--repo と --clear-delegated は一緒に使えません。"
  base=$(parent_state_dir "$PARENT")
  if [[ -n $REPO ]]; then
    mkdir -p "$base/repos/$(repo_key "$REPO")"
    RECORD=$base/repos/$(repo_key "$REPO")/last-result
  else
    RECORD=$base/last-result
  fi
  ! $CLEAR || rm -f "$base/delegated"
else
  [[ -z $REPO ]] && ! $CLEAR || die "--repo・--clear-delegated は --parent と一緒に使ってください。"
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "git リポジトリの中で実行してください。"
  RECORD=$(state_dir)/last-result${PR:+-pr-$PR}
fi
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
