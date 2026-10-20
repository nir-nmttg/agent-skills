#!/usr/bin/env bash
# このリポジトリのスキルをすべて ~/.claude/skills/ にシンボリックリンクし、
# どのフォルダで Claude Code を開いても使えるようにする。
#
# 使い方: scripts/link-skills.sh
#   - 未リンクのスキルはリンクを作る（このリポジトリを指すリンクは張り直す）
#   - 同名で切れたリンクは、別の場所を指していても張り直す（リポジトリを移したとき）
#   - 同名の別ディレクトリや、別の場所への切れていないリンクがあれば、触らずに警告する
#   - 削除したスキルを指したまま切れているリンクは取り除く
set -euo pipefail

repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src_dir="$repo_root/.claude/skills"
dest_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"

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
      echo "relinked $name（リンク切れ: ${current}）"
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
