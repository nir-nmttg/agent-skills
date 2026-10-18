#!/usr/bin/env bash
# 標準入力の確認レポート（Markdown）を保存し、保存先のパスを出力する。
#
# 使い方: save-report.sh <PR の URL | owner/repo#番号> <<'__REPORT__'
#         （レポートの Markdown）
#         __REPORT__
#
# 保存先: このリポジトリ直下の artifacts/gh-pr-precheck/<owner>/<repo>/pr-<番号>/report-<YYYYMMDD-HHMMSS>.md
set -euo pipefail

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

if [[ ${1:-} =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) ]] ||
   [[ ${1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
else
  usage
fi

report=$(cat)
if [[ -z ${report//[[:space:]]/} ]]; then
  echo "レポートの Markdown を標準入力で渡してください。" >&2
  exit 1
fi

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
dir="$repo_root/artifacts/gh-pr-precheck/$owner/$repo/pr-$number"
mkdir -p "$dir"
file="$dir/report-$(date +%Y%m%d-%H%M%S).md"
printf '%s\n' "$report" >"$file"
echo "保存: $file"
