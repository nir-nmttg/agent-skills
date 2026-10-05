#!/usr/bin/env bash
# GitHub Actions の失敗した実行から、失敗したステップのログだけを短くして出力する。
# ジョブ名・タイムスタンプ・後片付け（Post job cleanup 以降）の行は落とす。
#
# 使い方: ci-log.sh <実行 ID | 実行の URL> [ジョブごとの行数（既定 60）]
#   例: ci-log.sh https://github.com/owner/repo/actions/runs/123456789
set -euo pipefail

arg=${1:-} lines=${2:-60}
repo_opt=()
if [[ $arg =~ github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/actions/runs/([0-9]+) ]]; then
  repo_opt=(-R "${BASH_REMATCH[1]}") id=${BASH_REMATCH[2]}
elif [[ $arg =~ ^[0-9]+$ ]]; then
  id=$arg
else
  sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
fi
[[ $lines =~ ^[0-9]+$ ]] || lines=60

gh run view "$id" ${repo_opt[@]+"${repo_opt[@]}"} --log-failed |
  awk -F'\t' -v max="$lines" '
    {
      job = $1; msg = $0; sub(/^[^\t]*\t[^\t]*\t/, "", msg)
      sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?/, "", msg)
      gsub(/\033\[[0-9;]*m/, "", msg)
      if (job != cur) { cur = job; skip = 0; order[++n] = job; count[job] = 0 }
      if (msg ~ /^Post job cleanup\./) skip = 1
      if (skip || msg ~ /^[[:space:]]*$/) next
      buf[job, ++count[job]] = msg
    }
    END {
      for (i = 1; i <= n; i++) {
        j = order[i]; c = count[j]
        print "## " j "（最後の " (c < max ? c : max) " 行 / 全 " c " 行）"
        for (k = (c > max ? c - max + 1 : 1); k <= c; k++) print buf[j, k]
        print ""
      }
    }'
