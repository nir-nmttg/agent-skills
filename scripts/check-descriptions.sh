#!/usr/bin/env bash
# スキルの description の文字数を数え、上限を超えたものがないかを確かめる。
# Claude / Codex 別に、自動選択される description の文字数も出す。
#
# 使い方: scripts/check-descriptions.sh
#   - 1 行に「種類（auto / manual） 文字数/上限 スキル名」を出力する
#   - 上限: 自動で使う・確認されるスキルは 200 文字、明示的に呼び出すスキルは 120 文字
#   - Codex の agents/openai.yaml に short_description・default_prompt がないか、display_name があれば指摘する
#   - 上限超えか openai.yaml の指摘があれば終了コード 1
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
claude_context=0
codex_context=0
for f in "$repo_root"/.claude/skills/*/SKILL.md "$repo_root"/.agents/skills/*/SKILL.md; do
  [[ -f "$f" ]] || continue
  name=$(basename "$(dirname "$f")")
  if [[ "$f" == "$repo_root"/.agents/* ]]; then
    name="codex/$name"
  else
    name="claude/$name"
  fi
  frontmatter=$(awk '/^---$/ { n++; next } n == 1' "$f")
  desc=$(sed -n 's/^description:[[:space:]]*//p' <<<"$frontmatter")
  ui_config="$(dirname "$f")/agents/openai.yaml"
  if grep -q '^disable-model-invocation:[[:space:]]*true' <<<"$frontmatter" || {
    [[ "$name" == codex/* && -f "$ui_config" ]] &&
      grep -Eq '^[[:space:]]*allow_implicit_invocation:[[:space:]]*false([[:space:]]*(#.*)?)$' "$ui_config"
  }; then
    kind=manual limit=$manual_limit
  else
    kind=auto limit=$auto_limit
    if [[ "$name" == codex/* ]]; then
      codex_context=$((codex_context + ${#desc}))
    else
      claude_context=$((claude_context + ${#desc}))
    fi
  fi
  mark=""
  if (( ${#desc} > limit )); then
    mark="  ← 上限超え"
    over=1
  fi
  # Codex の openai.yaml は short_description・default_prompt を必須とし、display_name を禁止する
  if [[ "$name" == codex/* ]]; then
    for key in short_description default_prompt; do
      if [[ ! -f "$ui_config" ]] || ! grep -Eq "^[[:space:]]+${key}:[[:space:]]*[^[:space:]]" "$ui_config"; then
        mark+="  ← openai.yaml に ${key} がない"
        over=1
      fi
    done
    if [[ -f "$ui_config" ]] && grep -Eq '^[[:space:]]+display_name:' "$ui_config"; then
      mark+="  ← openai.yaml に display_name がある"
      over=1
    fi
  fi
  printf '%-6s %3d/%d  %s%s\n' "$kind" "${#desc}" "$limit" "$name" "$mark"
done
echo "自動選択用 description の合計: Claude ${claude_context} 文字 / Codex ${codex_context} 文字"

exit "$over"
