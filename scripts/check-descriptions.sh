#!/usr/bin/env bash
# スキルの description の文字数を数え、上限を超えたものがないかを確かめる。
# disable-model-invocation のないスキルの description は毎回コンテキストに入るので、その合計も出す。
#
# 使い方: scripts/check-descriptions.sh
#   - 1 行に「種類（auto / manual） 文字数/上限 スキル名」を出力する
#   - 上限: 自動で使う・確認されるスキルは 200 文字、明示的に呼び出すスキルは 120 文字
#   - 上限を超えたスキルがあれば終了コード 1
set -euo pipefail

auto_limit=200
manual_limit=120

# 日本語を 1 文字ずつ数えられるロケールを選ぶ
for loc in C.UTF-8 en_US.UTF-8; do
  if [[ $(LC_ALL=$loc bash -c 's=あ; echo ${#s}' 2>/dev/null) == 1 ]]; then
    export LC_ALL=$loc
    break
  fi
done

repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

over=0
in_context=0
for f in "$repo_root"/.claude/skills/*/SKILL.md; do
  name=$(basename "$(dirname "$f")")
  frontmatter=$(awk '/^---$/ { n++; next } n == 1' "$f")
  desc=$(sed -n 's/^description:[[:space:]]*//p' <<<"$frontmatter")
  if grep -q '^disable-model-invocation:[[:space:]]*true' <<<"$frontmatter"; then
    kind=manual limit=$manual_limit
  else
    kind=auto limit=$auto_limit
    in_context=$((in_context + ${#desc}))
  fi
  mark=""
  if (( ${#desc} > limit )); then
    mark="  ← 上限超え"
    over=1
  fi
  printf '%-6s %3d/%d  %s%s\n' "$kind" "${#desc}" "$limit" "$name" "$mark"
done
echo "毎回コンテキストに入る description の合計: ${in_context} 文字"

exit "$over"
