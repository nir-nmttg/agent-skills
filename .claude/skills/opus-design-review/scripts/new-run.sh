#!/usr/bin/env bash
# Opus の設計レビューの実行フォルダを作り、要件と設計書を書き込むパスを出力する。
#
# 使い方: new-run.sh <slug>
#   slug  設計の短い名前（英数字・ハイフン）。フォルダ名に使う
#
# 保存先は $OPUS_DESIGN_REVIEW_DIR（既定: このリポジトリ直下の artifacts/opus-design-review）/<日時>-<slug>/。
set -euo pipefail

slug=${1:-}
[[ $slug =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$ ]] || { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
root=${OPUS_DESIGN_REVIEW_DIR:-$repo_root/artifacts/opus-design-review}
dir="$root/$(date +%Y%m%d-%H%M%S)-$slug"
mkdir -p "$dir"

echo "実行フォルダ: $dir"
echo "要件: $dir/requirements.md"
echo "設計書: $dir/design.md"
