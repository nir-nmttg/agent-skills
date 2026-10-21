#!/usr/bin/env bash
# Claude Code / Codex のスキルを、それぞれのユーザー用ディレクトリへリンクする。
#
# 使い方: scripts/link-skills.sh [--all | --claude | --codex]
#   - 省略時は両方。Claude: ~/.claude/skills、Codex: ~/.agents/skills
#   - 未リンクのスキルはリンクを作る（このリポジトリを指すリンクは張り直す）
#   - 同名で切れたリンクは、別の場所を指していても張り直す（リポジトリを移したとき）
#   - 同名の別ディレクトリや、別の場所への切れていないリンクがあれば、触らずに警告する
#   - 削除したスキルを指したまま切れているリンクは取り除く
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
    echo "省略時は両方。Claude → ~/.claude/skills、Codex → ~/.agents/skills"
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
link_skills() {
  local src_dir=$1 dest_dir=$2 label=$3
  local skill name dest current link

  echo "[$label] $dest_dir"
  mkdir -p "$dest_dir"

  for skill in "$src_dir"/*/; do
    skill=${skill%/}
    name=$(basename "$skill")
    [[ -f "$skill/SKILL.md" ]] || continue
    dest="$dest_dir/$name"

    if [[ -L "$dest" ]]; then
      current=$(readlink "$dest")
      if [[ "$current" == "$skill" ]]; then
        echo "linked  $name"
        continue
      fi
      if [[ ! -e "$dest" ]]; then
        ln -sfn "$skill" "$dest"
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

    ln -sfn "$skill" "$dest"
    echo "added   $name"
  done

  # このリポジトリから消えたスキルを指す、切れたリンクを片付ける
  for link in "$dest_dir"/*; do
    [[ -L "$link" && ! -e "$link" ]] || continue
    [[ "$(readlink "$link")" == "$src_dir"/* ]] || continue
    rm "$link"
    echo "removed $(basename "$link")（リンク切れ）"
  done
}

if [[ "$target" == all || "$target" == claude ]]; then
  link_skills "$repo_root/.claude/skills" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" "Claude Code"
fi
if [[ "$target" == all || "$target" == codex ]]; then
  link_skills "$repo_root/.agents/skills" "$HOME/.agents/skills" "Codex"
fi
