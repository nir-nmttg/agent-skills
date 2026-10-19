#!/usr/bin/env bash
# clone していないリポジトリのコード（既定ブランチ）や PR を GitHub API で読む（読み取り専用）。
# 中身は gh-issue-overview の repo.sh に任せる。PR の head のファイルは pr-file.sh で読む。
#
# 使い方: repo.sh <tree|cat|grep|readme|search|log|pr|prs> <owner/repo> ...
#   サブコマンドの引数は gh-issue-overview/scripts/repo.sh の冒頭を参照
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../gh-issue-overview/scripts/repo.sh
[[ -f $base ]] || { echo "エラー: gh-issue-overview スキルが見つかりません（${base}）" >&2; exit 1; }

exec bash "$base" "$@"
