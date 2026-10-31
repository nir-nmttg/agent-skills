#!/usr/bin/env bash
# Sol と同じ指示書で依頼（prompt.md）を作る。処理は codex-design-review の prepare.sh に任せる。
#
# 使い方: prepare.sh [--cd <dir>] <実行フォルダ>
#   引数の意味は codex-design-review の prepare.sh と同じ
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../codex-design-review/scripts/prepare.sh
[[ -f $base ]] || { echo "エラー: codex-design-review スキルが見つかりません（${base}）" >&2; exit 1; }

exec bash "$base" "$@"
