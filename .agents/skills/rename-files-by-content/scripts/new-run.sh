#!/usr/bin/env bash
# リンク経由でも実体を基準に、改名計画と実行結果の保存先を作る。
set -euo pipefail

if (( $# != 0 )); then
  echo '使い方: bash scripts/new-run.sh' >&2
  exit 2
fi

script_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -P "$script_dir/../../../.." && pwd)
output_root="$repo_root/artifacts/rename-files-by-content"

if [[ -L "$repo_root/artifacts" || -L "$output_root" ]]; then
  echo '保存先がシンボリックリンクなので作成しません。artifacts の配置を確認してください。' >&2
  exit 1
fi

umask 077
mkdir -p "$output_root"
mktemp -d "$output_root/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX"
