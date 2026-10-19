#!/usr/bin/env bash
# runner が codex の作業を codex-impl に渡す。codex-impl の実行フォルダを作り、指示書を task.md としてコピーする。
#
# 使い方: to-codex.sh <計画フォルダ> <id>
#
# このあとは、出力された impl.sh のコマンドで実装させ、codex-impl の手順どおりに apply.sh で反映する。
set -euo pipefail

usage() { sed -n '4,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

(($# == 2)) || usage
dir=$(cd "$1" && pwd)
id=$2
brief="$dir/briefs/$id.md"
[[ -f $brief ]] || { echo "指示書がありません: $brief（先に plan-check.sh を実行する）" >&2; exit 1; }

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリの codex-impl を使う
skills_dir=$(cd -P "$(dirname "$0")/../.." && pwd)
new_run="$skills_dir/codex-impl/scripts/new-run.sh"
[[ -f $new_run ]] || { echo "codex-impl スキルが見つかりません: $new_run" >&2; exit 1; }

run_dir=$(bash "$new_run" "$id" | sed -n 's/^実行フォルダ: //p')
[[ -n $run_dir && -d $run_dir ]] || { echo "codex-impl の実行フォルダを作れませんでした" >&2; exit 1; }
cp "$brief" "$run_dir/task.md"

# plan.json の repo（対象のリポジトリ）があれば impl.sh に --cd で渡す。apply.sh は実行フォルダに記録された先に反映する
repo=$(jq -r 'if (.repo | type) == "string" then .repo else "" end' "$dir/plan.json")

echo "実行フォルダ: $run_dir"
echo "実装の指示: $run_dir/task.md（指示書をコピー済み）"
cmd=(bash "$skills_dir/codex-impl/scripts/impl.sh")
[[ -n $repo ]] && cmd+=(--cd "$repo")
cmd+=(--worktree "$run_dir")
# パスに空白があってもそのまま実行できるようにクォートする
echo "次: $(printf '%q ' "${cmd[@]}" | sed 's/ $//')（run_in_background で実行）"
