#!/usr/bin/env bash
# 作業フォルダの git の変更を取り出し、レビュアーに読ませる prompt.md を作る。
# Sol（review.sh）と Opus（opus-reviewer）は、ここで作った同じ prompt.md を読む。
#
# 使い方: prepare.sh [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] <実行フォルダ>
#   --cd と範囲の指定の意味は implementation-cross-review の prepare.sh と同じ（範囲を指定しなければ既定ブランチからの変更をすべて）。
#   new-run.sh --followup で作った実行フォルダ（previous.txt がある）は確認のレビューにし、範囲は指定できない。
#
# 1 回目のレビュー: 指示書、差分、コードを読む場所、作業場所のルートの CLAUDE.md・.claude/CLAUDE.md・AGENTS.md、
# <実行フォルダ>/constraints.md（あれば）を prompt.md にまとめる。確認のレビューに備えて、作業ツリーの
# スナップショット（snapshot.txt）・リポジトリ（repo.txt）・HEAD（head.txt）も残す。
# 確認のレビュー: 確認用の指示書、constraints.md（あれば）、fixes.md（直したことと決定済み）、前回のスナップショットから
# 今の作業ツリーまでの差分（fix.patch）を prompt.md にまとめる。
# 実行に使う source.txt・scope.txt も残す。失敗したときは prompt.md を残さない。
set -euo pipefail

usage() { sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

workdir=$PWD cd_given="" run_dir="" mode=auto target=""
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; cd_given=1; shift 2 || usage ;;
    --base | --commit)
      [[ $mode == auto ]] || usage
      mode=${1#--}; target=${2:-}; [[ -n $target ]] || usage; shift 2 ;;
    --uncommitted) [[ $mode == auto ]] || usage; mode=uncommitted; shift ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのファイルを使う
here=$(cd -P "$(dirname "$0")" && pwd)

[[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
# 途中で失敗したときに、前回の入力でレビューしないよう先に消す
rm -rf "$run_dir/prompt.md" "$run_dir/prompt.md.tmp" "$run_dir/source.txt" "$run_dir/scope.txt" "$run_dir/tree" \
  "$run_dir/diff.patch" "$run_dir/snapshot.txt" "$run_dir/repo.txt" "$run_dir/head.txt" "$run_dir/fix.patch"

lib=$here/../../implementation-cross-review/scripts/lib.sh
[[ -f $lib ]] || { echo "エラー: implementation-cross-review スキルが見つかりません（${lib}）" >&2; exit 1; }
# shellcheck source=/dev/null
. "$lib"

prompt_file=$here/../assets/review-prompt.md followup=""
if [[ -e $run_dir/previous.txt ]]; then
  followup=1 prompt_file=$here/../assets/followup-prompt.md
  [[ $mode == auto ]] || { echo "エラー: 確認のレビューでは範囲（--base / --commit / --uncommitted）を指定できません" >&2; exit 1; }
  prev=$(cat "$run_dir/previous.txt")
  [[ -d $prev ]] || { echo "エラー: 前回の実行フォルダ $prev がありません" >&2; exit 1; }
  prev=$(cd -P "$prev" && pwd)
  [[ $prev != "$run_dir" ]] || { echo "エラー: 前回の実行フォルダが今回と同じです" >&2; exit 1; }
  [[ -s $run_dir/fixes.md ]] || { echo "エラー: $run_dir/fixes.md がないか空です" >&2; exit 1; }
  # --cd を省いたら前回のリポジトリを使う（別の worktree の変更を、直したこととして読まないため）
  [[ -n $cd_given || ! -s $prev/repo.txt ]] || workdir=$(cat "$prev/repo.txt")
fi

[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
toplevel=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
workdir=$toplevel
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }

print_constraints() {
  [[ ! -s $run_dir/constraints.md ]] || print_tagged constraints "$run_dir/constraints.md"
}

if [[ -n $followup ]]; then
  # 前回のスナップショットから今の作業ツリーまでの差分を fix.patch に書き出す（scope・commits・files・lines・size を設定する）
  collect_fix_diff "$workdir" "$prev" "$run_dir"

  {
    cat "$prompt_file"
    print_fix_scope "$workdir" "$run_dir"
    print_project_instructions "$workdir"
    print_constraints
    print_tagged fixes "$run_dir/fixes.md"
    print_patch fix-diff "$run_dir/fix.patch" "$size"
  } >"$run_dir/prompt.md.tmp"
  finish_followup "$workdir" "$run_dir"
  exit 0
fi

# レビューする範囲を決め、差分を diff.patch に書き出す（scope・commits・stat・untracked・source・files・lines・size を設定する）
collect_diff "$workdir" "$run_dir" "$mode" "$target"

# 確認のレビューに備えて、今の作業ツリーを記録する（直したことは作業ツリーに入るので、--commit でも作業ツリーで取る）。
# 取れなくてもこのレビューは続ける（そのときの再レビューは、--followup を付けずに全体の差分で行う）
tree_id=$(snapshot "$workdir" 2>/dev/null) || { tree_id=""; echo "注意: 作業ツリーのスナップショットを取れませんでした。確認のレビューは使えません" >&2; }

{
  cat "$prompt_file"
  print_diff_scope "$workdir" "$run_dir"
  print_project_instructions "$source"
  print_constraints
  print_patch diff "$run_dir/diff.patch" "$size"
} >"$run_dir/prompt.md.tmp"
finish_review "$workdir" "$run_dir" "$tree_id"
