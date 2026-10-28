#!/usr/bin/env bash
# 実装を任せる実行フォルダを作り、実装の指示を書き込むパスを出力する。
#
# 使い方: new-run.sh <slug>
#   slug  タスクの短い名前（英数字・ハイフン）。フォルダ名に使う
#
# 保存先はこのリポジトリ直下の artifacts/haiku-impl/<日時>-<slug>/。
set -euo pipefail

slug=${1:-}
[[ $slug =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$ ]] || { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

source "$(dirname "$0")/lib.sh"
root=$(runs_root)
dir="$root/$(date +%Y%m%d-%H%M%S)-$slug"
mkdir -p "$dir"

echo "実行フォルダ: $dir"
echo "実装の指示: $dir/task.md"
echo "修正の依頼（2 回目以降）: $dir/feedback.md"
