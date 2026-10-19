#!/usr/bin/env bash
# 並列化の計画フォルダを作り、計画（plan.json）を書き込むパスを出力する。
#
# 使い方: new-plan.sh <slug>
#   slug  作業全体の短い名前（英数字・ハイフン）。フォルダ名に使う
#
# 保存先は $PARALLEL_TASKS_DIR（既定: このリポジトリ直下の artifacts/parallel-tasks）/<日時>-<slug>/。
set -euo pipefail

slug=${1:-}
[[ $slug =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$ ]] || { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
root=${PARALLEL_TASKS_DIR:-$repo_root/artifacts/parallel-tasks}
dir="$root/$(date +%Y%m%d-%H%M%S)-$slug"
mkdir -p "$dir"

echo "計画フォルダ: $dir"
echo "計画: $dir/plan.json"
