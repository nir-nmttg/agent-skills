#!/usr/bin/env bash
# Haiku に実装させる worktree を用意し、haiku-implementer に読ませる prompt.md を作る。
#
# 使い方: prepare.sh [--cd <dir>] <実行フォルダ>
#   --cd  実装するリポジトリ（既定: 今のフォルダ）
#
# 作業フォルダの今の状態（未コミットの変更を含む）を HEAD の子コミットにし、そこから <実行フォルダ>/worktree を切る。
# ブランチや本物のインデックスには触れない。作業フォルダにある依存パッケージのフォルダ（.gitignore 対象の
# node_modules / .venv / venv / .bundle / vendor。HAIKU_IMPLEMENTATION_LINK_DIRS で変えられる）は worktree にリンクする。
# prompt.md には、作業場所、ロックのコマンド、worktree のルートの CLAUDE.md・.claude/CLAUDE.md・AGENTS.md、
# <実行フォルダ>/task.md をまとめる（haiku-implementer は omitClaudeMd で CLAUDE.md を自動では読まない）。
set -euo pipefail

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
source "$(dirname "$0")/lib.sh"

workdir=$PWD run_dir=""
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; shift 2 || usage ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

script_dir=$(cd -P "$(dirname "$0")" && pwd)
[[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
[[ -s $run_dir/task.md ]] || { echo "エラー: $run_dir/task.md がないか空です" >&2; exit 1; }
[[ ! -e $run_dir/repo ]] || { echo "エラー: この実行フォルダは準備済みです。続きは同じ Haiku に SendMessage で頼むか、新しい実行フォルダを作ってください" >&2; exit 1; }
root=$(runs_root) || exit 1
root_real=$(cd -P "$root" 2>/dev/null && pwd) || { echo "エラー: 実行フォルダの置き場所 $root がありません。new-run.sh で作ってください" >&2; exit 1; }
[[ $run_dir == "$root_real"/* ]] ||
  { echo "エラー: 実行フォルダが $root の下にありません（guard.sh が作業場所として認めません）。new-run.sh で作ってください" >&2; exit 1; }

# haiku-implementer の hook は、ユーザー用のスキルのリンクから guard.sh を呼ぶ。リンクが別の場所を指していると、
# 古い guard.sh が動いたり、見つからずにすべての操作が止まったりするので、先に確かめる
config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
linked_guard=$config_dir/skills/haiku-implementation/scripts/guard.sh
if [[ ! -f $linked_guard ]] || [[ $(cd -P "$(dirname "$linked_guard")" && pwd) != "$script_dir" ]]; then
  echo "エラー: $linked_guard がこのスキルの guard.sh を指していません。このスキル集の scripts/link-skills.sh --claude でリンクしてください" >&2
  exit 1
fi
[[ -f $config_dir/agents/haiku-implementer.md ]] ||
  echo "注意: $config_dir/agents/haiku-implementer.md がありません。このリポジトリの .claude/agents にない限り、haiku-implementer を呼べません（scripts/link-skills.sh --claude でリンクする）" >&2

[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
repo=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
git -C "$repo" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $repo にはまだコミットがありません" >&2; exit 1; }

wt=$run_dir/worktree
[[ ! -e $wt ]] || { echo "エラー: $wt がすでにあります。apply.sh --discard $run_dir で片づけるか、新しい実行フォルダを作ってください" >&2; exit 1; }
# 途中で失敗したら、作った worktree と記録を片づけて、同じ実行フォルダで準備し直せるようにする
done=""
cleanup() {
  [[ -z $done ]] || return 0
  [[ ! -e $wt ]] || git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  rm -f "$run_dir/linked" "$run_dir/base-tree" "$run_dir/last-tree" "$run_dir/base-commit" "$run_dir/prompt.md"
}
trap cleanup EXIT
base_tree=$(snapshot "$repo")
base_commit=$(GIT_AUTHOR_NAME=haiku-implementation GIT_AUTHOR_EMAIL=haiku-implementation@localhost \
  GIT_COMMITTER_NAME=haiku-implementation GIT_COMMITTER_EMAIL=haiku-implementation@localhost \
  git -C "$repo" commit-tree "$base_tree" -p HEAD -m "haiku-implementation base")
git -C "$repo" -c core.hooksPath=/dev/null worktree add -q --detach "$wt" "$base_commit"

# 依存パッケージのフォルダをリンクし、Haiku がテストを動かせるようにする（差分からは除く）
: >"$run_dir/linked"
link_names=" ${HAIKU_IMPLEMENTATION_LINK_DIRS:-node_modules .venv venv .bundle vendor} "
while IFS= read -r -d '' d; do
  d=${d%/}
  [[ $link_names == *" ${d##*/} "* && ! -e $wt/$d ]] || continue
  mkdir -p "$(dirname "$wt/$d")"
  ln -s "$repo/$d" "$wt/$d"
  echo "$d" >>"$run_dir/linked"
done < <(git -C "$repo" ls-files -z --others --ignored --exclude-standard --directory)

echo "$base_tree" >"$run_dir/base-tree"
echo "$base_tree" >"$run_dir/last-tree"
echo "$base_commit" >"$run_dir/base-commit"

wt_real=$(cd -P "$wt" && pwd)
{
  echo "# 実装の依頼"
  echo
  echo "- 作業場所（worktree）: $wt"
  echo "- 実行フォルダ: $run_dir"
  echo "- もとのリポジトリ（参照のみ。変更しない）: $repo"
  echo "- DB や Docker を使うテストを実行するときのロック: \`cd $wt && bash $script_dir/locked.sh <コマンド>\`"
  if [[ -s $run_dir/linked ]]; then
    echo "- もとのリポジトリへのリンク（書き込まない）: $(paste -sd, "$run_dir/linked" | sed 's/,/, /g')"
  fi
  seen=" "
  for f in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do
    [[ -f $wt/$f ]] || continue
    # リンクで worktree の外のファイル（秘密情報など）を取り込まないよう、実体が worktree の中のものだけを渡す
    real=$(real_path "$wt/$f") && [[ $real == "$wt_real"/* ]] || { echo "注意: $f は worktree の外を指しているので渡しません" >&2; continue; }
    sum=$(cksum <"$wt/$f" | tr ' ' -)
    [[ $seen != *" $sum "* ]] || continue
    seen+="$sum "
    printf '\n## プロジェクトの指示（%s）\n\n' "$f"
    echo "このリポジトリの $f の内容です。<task> と食い違うときは <task> を優先してください。"
    printf '\n<project-instructions file="%s">\n' "$f"
    cat "$wt/$f"
    printf '\n</project-instructions>\n'
  done
  printf '\n<task>\n'
  cat "$run_dir/task.md"
  printf '\n</task>\n'
} >"$run_dir/prompt.md"

# repo は最後に書く（guard.sh はこれがある実行フォルダだけを作業場所として認め、prepare.sh は準備済みとみなす）
echo "$repo" >"$run_dir/repo"
done=1

echo "作業場所: ${wt}（$repo の worktree）"
echo "プロンプト: $run_dir/prompt.md"
[[ ! -s $run_dir/linked ]] || echo "リンクした依存フォルダ: $(paste -sd, "$run_dir/linked" | sed 's/,/, /g')"
[[ $base_tree == "$(git -C "$repo" rev-parse 'HEAD^{tree}')" ]] || echo "注意: 未コミットの変更を含めて worktree を切りました"
