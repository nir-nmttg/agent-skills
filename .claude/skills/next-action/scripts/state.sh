#!/usr/bin/env bash
# 今のフォルダの作業の状態（ブランチ・未コミットの変更・最近のコミット・PR）を Markdown で出力する。
# 次にやることを判断する材料にするだけで、何も変更しない。
#
# 使い方: state.sh
set -uo pipefail

echo "- フォルダ: \`$PWD\`"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "- git リポジトリではない"
  exit 0
fi

branch=$(git branch --show-current 2>/dev/null)
echo "- ブランチ: \`${branch:-（detached HEAD）}\`"

# 既定ブランチ（origin/HEAD がなければ main / master のうちあるもの）との差
base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
if [[ -z "$base" ]]; then
  for b in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$b" >/dev/null; then base=$b; break; fi
  done
fi
if [[ -n "$base" && "$branch" != "${base#origin/}" ]]; then
  ahead=$(git rev-list --count "$base..HEAD" 2>/dev/null || echo "?")
  behind=$(git rev-list --count "HEAD..$base" 2>/dev/null || echo "?")
  echo "- \`$base\` との差: $ahead コミット先行 / $behind コミット遅れ"
fi

# push していないコミット
if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
  unpushed=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo "?")
  echo "- push していないコミット: ${unpushed}（追跡先 \`$upstream\`）"
elif [[ -n "$branch" ]]; then
  echo "- push していないコミット: 追跡先なし（まだ push していない）"
fi

# 未コミットの変更
changes=$(git status --porcelain 2>/dev/null)
if [[ -z "$changes" ]]; then
  echo "- 未コミットの変更: なし"
else
  count=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
  echo "- 未コミットの変更: $count ファイル"
  echo '```'
  printf '%s\n' "$changes" | head -n 20
  [[ "$count" -gt 20 ]] && echo "...（ほか $((count - 20)) ファイル）"
  echo '```'
fi

echo "- 最近のコミット:"
echo '```'
git log -n 5 --format='%h %ad %s' --date=format:'%m/%d %H:%M' 2>/dev/null
echo '```'

# 今のブランチの PR（gh があってログイン済みのときだけ）
if [[ -n "$branch" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  pr=$(gh pr view --json number,title,url,state,isDraft,reviewDecision,mergeable,statusCheckRollup --jq '
    def ci: [.statusCheckRollup[]? | [.conclusion, .state, .status] | map(select(. != null and . != "")) | first] as $s
      | if ($s | length) == 0 then "なし"
        elif any($s[]; . == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED") then "失敗あり"
        elif any($s[]; . == "IN_PROGRESS" or . == "QUEUED" or . == "PENDING" or . == "EXPECTED") then "実行中"
        else "成功" end;
    "- PR: [#\(.number) \(.title)](\(.url))（\(.state)\(if .isDraft then "・draft" else "" end)、レビュー: \(if (.reviewDecision // "") == "" then "なし" else .reviewDecision end)、CI: \(ci)、マージ可否: \(.mergeable)）"
  ' 2>/dev/null)
  echo "${pr:-- PR: なし}"
fi
