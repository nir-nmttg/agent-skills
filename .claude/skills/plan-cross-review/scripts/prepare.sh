#!/usr/bin/env bash
# 要件・設計書・指示書をまとめて、レビュアーに読ませる prompt.md を作る。
# Astra（review.sh）と Fable（fable-reviewer。Fable の代わりは opus-reviewer）は、ここで作った同じ prompt.md を読む。
#
# 使い方: prepare.sh [--cd <dir>] <実行フォルダ>
#   --cd  レビュアーが既存コードを確かめる作業フォルダ（既定: 今のフォルダ。確認のレビューでは前回の作業フォルダ）
#   new-run.sh --followup で作った実行フォルダ（previous.txt がある）は確認のレビューにし、確認用の指示書・
#   fixes.md（直したことと決定済み）・直した設計書の全体・前回の設計書からの差分（design-diff.patch）をまとめる。
#
# 実行に使う source.txt・scope.txt も残す。失敗したときは prompt.md を残さない。
set -euo pipefail

usage() { sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

workdir=$PWD cd_given="" run_dir=""
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; cd_given=1; shift 2 || usage ;;
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
rm -f "$run_dir/prompt.md" "$run_dir/prompt.md.tmp" "$run_dir/source.txt" "$run_dir/scope.txt" "$run_dir/design-diff.patch"

lib=$here/../../implementation-cross-review/scripts/lib.sh
[[ -f $lib ]] || { echo "エラー: implementation-cross-review スキルが見つかりません（${lib}）" >&2; exit 1; }
# shellcheck source=/dev/null
. "$lib"

prompt_file=$here/../assets/review-prompt.md followup=""
if [[ -e $run_dir/previous.txt ]]; then
  followup=1 prompt_file=$here/../assets/followup-prompt.md
  prev=$(cat "$run_dir/previous.txt")
  [[ -d $prev ]] || { echo "エラー: 前回の実行フォルダ $prev がありません" >&2; exit 1; }
  prev=$(cd -P "$prev" && pwd)
  [[ $prev != "$run_dir" ]] || { echo "エラー: 前回の実行フォルダが今回と同じです" >&2; exit 1; }
  [[ -s $prev/design.md ]] || { echo "エラー: 前回の設計書 $prev/design.md がありません" >&2; exit 1; }
  [[ -s $run_dir/fixes.md ]] || { echo "エラー: $run_dir/fixes.md がないか空です" >&2; exit 1; }
  # --cd を省いたら前回の作業フォルダを使う
  [[ -n $cd_given || ! -s $prev/source.txt ]] || workdir=$(cat "$prev/source.txt")
fi

[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
[[ -s $run_dir/requirements.md ]] || { echo "エラー: $run_dir/requirements.md がないか空です" >&2; exit 1; }
[[ -s $run_dir/design.md ]] || { echo "エラー: $run_dir/design.md がないか空です" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
# 読む場所は、設計書の相対パスの基準である作業フォルダにする。プロジェクトの指示はリポジトリのルートから読む
source=$(cd -P "$workdir" && pwd)
root=$(git -C "$source" rev-parse --show-toplevel 2>/dev/null) || root=$source
scope="設計書（作業フォルダ: ${source}）"

if [[ -n $followup ]]; then
  # --no-index は差分があると 1 で終わる。それ以外の失敗は止める
  rc=0
  git diff --no-index -- "$prev/design.md" "$run_dir/design.md" >"$run_dir/design-diff.patch" || rc=$?
  ((rc <= 1)) || { echo "エラー: 設計書の差分を作れませんでした" >&2; exit 1; }
  [[ -s $run_dir/design-diff.patch ]] || { echo "エラー: 設計書が前回から変わっていません" >&2; exit 1; }
  scope="確認のレビュー（前回: $(basename "$prev")、作業フォルダ: ${source}）"
fi

{
  cat "$prompt_file"
  printf '\n\n<scope>\n'
  echo "コードを読む場所: $source"
  printf '</scope>\n'
  print_project_instructions "$root"
  printf '\n<requirements>\n'
  cat "$run_dir/requirements.md"
  printf '\n</requirements>\n'
  if [[ -n $followup ]]; then
    printf '\n<fixes>\n'
    cat "$run_dir/fixes.md"
    printf '\n</fixes>\n'
  fi
  printf '\n<design>\n'
  cat "$run_dir/design.md"
  printf '\n</design>\n'
  if [[ -n $followup ]]; then
    printf '\n<design-diff>\n'
    cat "$run_dir/design-diff.patch"
    printf '</design-diff>\n'
  fi
} >"$run_dir/prompt.md.tmp"

echo "$source" >"$run_dir/source.txt"
echo "$scope" >"$run_dir/scope.txt"
mv "$run_dir/prompt.md.tmp" "$run_dir/prompt.md"

echo "範囲: $scope"
echo "プロンプト: $run_dir/prompt.md"
