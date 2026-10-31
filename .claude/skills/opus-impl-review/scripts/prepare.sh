#!/usr/bin/env bash
# Sol と同じ依頼（prompt.md）を作る。処理は codex-impl-review の prepare.sh に任せる。
#
# 使い方: prepare.sh [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] <実行フォルダ>
#   引数の意味は codex-impl-review の prepare.sh と同じ
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../codex-impl-review/scripts/prepare.sh
[[ -f $base ]] || { echo "エラー: codex-impl-review スキルが見つかりません（${base}）" >&2; exit 1; }

exec bash "$base" "$@"
