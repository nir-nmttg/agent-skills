#!/usr/bin/env bash
# Codex 版 security-audit-verify-items の verify.mjs を共有して実行する（定型処理を 2 か所に持たないため）。
#   verify.sh <サブコマンド> ...  verify.mjs に引数と標準入力をそのまま渡す（終了コードも verify.mjs のもの）
#   verify.sh refs                verify.mjs があることを確かめ、sync-issues の参照ファイルのフォルダを出す（ないなら終了コード 1）
# ~/.claude/skills のリンク経由で呼ばれても、cd -P でこのスキル集のリポジトリを特定する。
set -euo pipefail

repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
script="$repo_root/.agents/skills/security-audit-verify-items/scripts/verify.mjs"
refs="$repo_root/.agents/skills/security-audit-sync-issues/references"

if [[ ${1-} == refs ]]; then
  for f in "$script" "$refs/issue-sync.md" "$refs/issue-templates.md"; do
    [[ -f $f ]] || { echo "見つかりません: $f" >&2; exit 1; }
  done
  echo "$refs"
  exit 0
fi

exec node "$script" "$@"
