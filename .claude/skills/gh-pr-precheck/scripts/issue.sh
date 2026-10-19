#!/usr/bin/env bash
# Issue の本文・コメント・関連 Issue / PR・リポジトリ概要を取得する。
# 取得と整形は gh-issue-overview の fetch-issue.sh に任せる。
#
# 使い方: issue.sh <Issue の URL | owner/repo#番号>
set -euo pipefail

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../gh-issue-overview/scripts/fetch-issue.sh
[[ -f $base ]] || { echo "エラー: gh-issue-overview スキルが見つかりません（${base}）" >&2; exit 1; }

exec bash "$base" "$@"
