#!/usr/bin/env bash
# 設計レビューの実行フォルダを作り、要件と設計書を書き込むパスを出力する。
#
# 使い方: new-run.sh [--followup <前回の実行フォルダ>] <slug>
#   --followup  確認のレビュー（再レビュー）にする。前回の要件と設計書を写し、前回のフォルダを previous.txt に、今回のフォルダを前回の followup.txt に残す
#   slug        設計の短い名前（英数字・ハイフン）。フォルダ名に使う
#
# 保存先は ${DESIGN_CROSS_REVIEW_DIR}（既定: このリポジトリ直下の artifacts/design-cross-review）/<日時>-<slug>.<乱数>/。
set -euo pipefail

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

prev="" slug=""
while (($#)); do
  case $1 in
    --followup) prev=${2:-}; [[ -n $prev ]] || usage; shift 2 ;;
    -*) usage ;;
    *) [[ -z $slug ]] || usage; slug=$1; shift ;;
  esac
done
[[ $slug =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$ ]] || usage

if [[ -n $prev ]]; then
  [[ -d $prev ]] || { echo "エラー: 前回の実行フォルダ $prev がありません" >&2; exit 1; }
  prev=$(cd -P "$prev" && pwd)
  for f in requirements.md design.md; do
    [[ -s $prev/$f ]] || { echo "エラー: 前回の $prev/$f がありません" >&2; exit 1; }
  done
  # 再レビューは 1 回までなので、確認のレビューの続きも、同じ 1 回目からの 2 つ目も作らない
  [[ ! -e $prev/previous.txt ]] || { echo "エラー: 再レビューは 1 回までです（前回は確認のレビューです）。残る指摘はユーザーに伝えてください" >&2; exit 1; }
  [[ ! -s $prev/followup.txt ]] || { echo "エラー: 再レビューは 1 回までです（確認のレビューを作成済み: $(cat "$prev/followup.txt")）。作ったフォルダを使うか、残る指摘をユーザーに伝えてください" >&2; exit 1; }
fi

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
root=${DESIGN_CROSS_REVIEW_DIR:-$repo_root/artifacts/design-cross-review}
mkdir -p "$root"
# 同時に動かしても別のフォルダになるよう、原子的に作る
dir=$(mktemp -d "$root/$(date +%Y%m%d-%H%M%S)-$slug.XXXXXX")

echo "実行フォルダ: $dir"
if [[ -n $prev ]]; then
  cp "$prev/requirements.md" "$prev/design.md" "$dir/"
  echo "$prev" >"$dir/previous.txt"
  echo "$dir" >"$prev/followup.txt"
  echo "要件（前回から写した）: $dir/requirements.md"
  echo "設計書（前回から写した。直した節を Edit する）: $dir/design.md"
  echo "修正の一覧: $dir/fixes.md"
else
  echo "要件: $dir/requirements.md"
  echo "設計書: $dir/design.md"
fi
