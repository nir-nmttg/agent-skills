#!/usr/bin/env bash
# Claude Code / Codex のスキル（Claude Code はサブエージェントの定義も）を、それぞれのユーザー用ディレクトリへリンクする。
#
# 使い方: scripts/link-skills.sh [--all | --claude | --codex]
#   - 省略時は両方。Claude: ~/.claude/skills と ~/.claude/agents、Codex: ~/.agents/skills
#   - 未リンクのスキル・エージェントはリンクを作る（このリポジトリを指すリンクは張り直す）
#   - 同名で切れたリンクは、別の場所を指していても張り直す（リポジトリを移したとき）
#   - 同名の別ファイル・ディレクトリや、別の場所への切れていないリンクがあれば、触らずに警告する
#   - 削除したスキル・エージェントを指したまま切れているリンクは取り除く
#   - git worktree の中で実行したときは、何もせずにメインの checkout で実行し直すよう案内する
set -euo pipefail

target=all
if (( $# > 1 )); then
  echo "使い方: scripts/link-skills.sh [--all | --claude | --codex]" >&2
  exit 2
fi
case "${1:---all}" in
  --all) target=all ;;
  --claude) target=claude ;;
  --codex) target=codex ;;
  -h|--help)
    echo "使い方: scripts/link-skills.sh [--all | --claude | --codex]"
    echo "省略時は両方。Claude → ~/.claude/skills・~/.claude/agents、Codex → ~/.agents/skills"
    exit 0 ;;
  *) echo "不明な引数: $1" >&2; exit 2 ;;
esac

repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# worktree の中を指すリンクは、worktree を片付けると切れるので張らない
if git_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-dir 2>/dev/null) &&
  common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  [[ "$git_dir" != "$common_dir" ]]; then
  echo "git worktree の中なのでリンクしません。メインの checkout で実行し直してください:" >&2
  echo "  $(dirname "$common_dir")/scripts/link-skills.sh" >&2
  exit 1
fi
# link_entries <src_dir> <dest_dir> <label> <skills | agents>
# skills は SKILL.md のあるフォルダを、agents は <名前>.md のファイルを、同じ名前でリンクする
link_entries() {
  local src_dir=$1 dest_dir=$2 label=$3 kind=$4
  local entry name dest current link

  echo "[$label] $dest_dir"
  mkdir -p "$dest_dir"

  for entry in "$src_dir"/*; do
    if [[ $kind == skills ]]; then
      [[ -f "$entry/SKILL.md" ]] || continue
    else
      [[ -f "$entry" && "$entry" == *.md ]] || continue
    fi
    name=$(basename "$entry")
    dest="$dest_dir/$name"

    if [[ -L "$dest" ]]; then
      current=$(readlink "$dest")
      if [[ "$current" == "$entry" ]]; then
        echo "linked  $name"
        continue
      fi
      if [[ ! -e "$dest" ]]; then
        ln -sfn "$entry" "$dest"
        echo "relinked ${name}（リンク切れ: ${current}）"
        continue
      fi
      if [[ "$current" != "$src_dir"/* ]]; then
        echo "skip $name: 別の場所へのリンクがあります（${current}）" >&2
        continue
      fi
    elif [[ -e "$dest" ]]; then
      echo "skip $name: 同名のファイルかディレクトリがあります（${dest}）" >&2
      continue
    fi

    ln -sfn "$entry" "$dest"
    echo "added   $name"
  done

  # このリポジトリから消えたスキル・エージェントを指す、切れたリンクを片付ける
  for link in "$dest_dir"/*; do
    [[ -L "$link" && ! -e "$link" ]] || continue
    [[ "$(readlink "$link")" == "$src_dir"/* ]] || continue
    rm "$link"
    echo "removed $(basename "$link")（リンク切れ）"
  done
}

if [[ "$target" == all || "$target" == claude ]]; then
  link_entries "$repo_root/.claude/skills" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" "Claude Code" skills
  link_entries "$repo_root/.claude/agents" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents" "Claude Code（エージェント）" agents
fi
if [[ "$target" == all || "$target" == codex ]]; then
  link_entries "$repo_root/.agents/skills" "$HOME/.agents/skills" "Codex" skills
fi
