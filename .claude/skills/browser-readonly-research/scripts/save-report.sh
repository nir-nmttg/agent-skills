#!/usr/bin/env bash
# 標準入力の調査レポート（Markdown）を保存し、保存先のパスを出力する。
#
# 使い方: save-report.sh <スラッグ> <<'__REPORT__'
#         （レポートの Markdown）
#         __REPORT__
#   スラッグ: ファイル名に使う短い英数字（例: notion-release-plan）。英数字と - 以外は - に置き換える
#
# 保存先: このリポジトリ直下の artifacts/browser-readonly-research/<YYYYMMDD-HHMMSS>-<スラッグ>.md
set -euo pipefail

usage() { sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

(($# == 1)) || usage
slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//' | cut -c1-60)
slug=${slug%-}
[[ -n $slug ]] || slug=report

report=$(cat)
if [[ -z ${report//[[:space:]]/} ]]; then
  echo "レポートの Markdown を標準入力で渡してください。" >&2
  exit 1
fi

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
dir="$repo_root/artifacts/browser-readonly-research"
mkdir -p "$dir"
file="$dir/$(date +%Y%m%d-%H%M%S)-$slug.md"
printf '%s\n' "$report" >"$file"
echo "保存: $file"
