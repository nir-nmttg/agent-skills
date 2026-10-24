#!/usr/bin/env bash
# 実行ごとの報告先を、このリポジトリの artifacts/<skill-name>/ に作る。
# 使い方: bash scripts/new-run.sh <project-slug>
set -euo pipefail

if (( $# != 1 )) || [[ ! $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,59}$ ]]; then
  echo '使い方: bash scripts/new-run.sh <project-slug>（英数字・_・-、先頭は英数字、60文字以内）' >&2
  exit 2
fi

# ユーザー用ディレクトリのリンク経由でも、実体から保存先を決める。
script_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
skill_dir=$(cd -P "$script_dir/.." && pwd)
repo_root=$(cd -P "$skill_dir/../../.." && pwd)
skill_name=${skill_dir##*/}
output_root="$repo_root/artifacts/$skill_name"

# 保存先を別の場所へ向けるリンクは辿らない。
if [[ -L "$repo_root/artifacts" || -L "$output_root" ]]; then
  echo '保存先がシンボリックリンクなので作成しません。artifacts の配置を確認してください。' >&2
  exit 1
fi

umask 077
mkdir -p "$output_root"
mktemp -d "$output_root/$(date -u +%Y%m%dT%H%M%SZ)-$1.XXXXXX"
