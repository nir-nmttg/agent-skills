#!/usr/bin/env bash
# 標準入力の動作確認の依頼プロンプト（Markdown）を保存し、保存先のパスを出力する。
#
# 使い方: save-prompt.sh [PR の URL | owner/repo#番号] <<'__PROMPT__'
#         （プロンプトの Markdown）
#         __PROMPT__
#
# 保存先: このリポジトリ直下の artifacts/codex-verify-prompt/ の下
#   PR あり: <owner>/<repo>/pr-<番号>/prompt-<YYYYMMDD-HHMMSS>.md
#   PR なし: session/<今のフォルダのリポジトリ名>/<ブランチ>-prompt-<YYYYMMDD-HHMMSS>.md
set -euo pipefail

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
skills_repo=$(cd -P "$(dirname "$0")/../../../.." && pwd)
out_root="$skills_repo/artifacts/codex-verify-prompt"
stamp=$(date +%Y%m%d-%H%M%S)

if [[ -n ${1:-} ]]; then
  if [[ $1 =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) ]] ||
     [[ $1 =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
    dir="$out_root/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/pr-${BASH_REMATCH[3]}"
    file="$dir/prompt-$stamp.md"
  else
    usage
  fi
else
  root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
  branch=$(git branch --show-current 2>/dev/null || true)
  dir="$out_root/session/$(basename "$root")"
  file="$dir/$(tr '/' '-' <<<"${branch:-detached}")-prompt-$stamp.md"
fi

prompt=$(cat)
if [[ -z ${prompt//[[:space:]]/} ]]; then
  echo "プロンプトの Markdown を標準入力で渡してください。" >&2
  exit 1
fi

mkdir -p "$dir"
printf '%s\n' "$prompt" >"$file"
echo "保存: $file"
