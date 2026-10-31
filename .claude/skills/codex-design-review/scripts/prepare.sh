#!/usr/bin/env bash
# 要件・設計書・指示書をまとめて、レビュアーに読ませる prompt.md を作る。
# Sol（review.sh）と Opus（opus-reviewer）は、ここで作った同じ prompt.md を読む。
#
# 使い方: prepare.sh [--cd <dir>] <実行フォルダ>
#   --cd  レビュアーが既存コードを確かめる作業フォルダ（既定: 今のフォルダ）
#
# 実行に使う source.txt・scope.txt も残す。失敗したときは prompt.md を残さない。
# 環境変数 CODEX_DESIGN_REVIEW_PROMPT で指示書を、CODEX_DESIGN_REVIEW_INPUT で入力（requirements-design / design）を
# 変えられる（codex-risk-design-review が使う）。
set -euo pipefail

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

workdir=$PWD run_dir=""
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; shift 2 || usage ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのファイルを使う
here=$(cd -P "$(dirname "$0")" && pwd)
prompt_file=${CODEX_DESIGN_REVIEW_PROMPT:-$here/../assets/review-prompt.md}

[[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
# 途中で失敗したときに、前回の入力でレビューしないよう先に消す
rm -f "$run_dir/prompt.md" "$run_dir/prompt.md.tmp" "$run_dir/source.txt" "$run_dir/scope.txt"

lib=$here/../../codex-impl-review/scripts/lib.sh
[[ -f $lib ]] || { echo "エラー: codex-impl-review スキルが見つかりません（${lib}）" >&2; exit 1; }
# shellcheck source=/dev/null
. "$lib"

input=${CODEX_DESIGN_REVIEW_INPUT:-requirements-design}
case $input in
  requirements-design | design) ;;
  *) echo "エラー: 入力 '$input' には対応していません（requirements-design / design）" >&2; exit 1 ;;
esac
[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
if [[ $input == requirements-design ]]; then
  [[ -s $run_dir/requirements.md ]] || { echo "エラー: $run_dir/requirements.md がないか空です" >&2; exit 1; }
fi
[[ -s $run_dir/design.md ]] || { echo "エラー: $run_dir/design.md がないか空です" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
# 読む場所は、設計書の相対パスの基準である作業フォルダにする。プロジェクトの指示はリポジトリのルートから読む
source=$(cd -P "$workdir" && pwd)
root=$(git -C "$source" rev-parse --show-toplevel 2>/dev/null) || root=$source
scope="設計書（作業フォルダ: $source）"

{
  cat "$prompt_file"
  printf '\n\n<scope>\n'
  echo "コードを読む場所: $source"
  printf '</scope>\n'
  print_project_instructions "$root"
  if [[ $input == requirements-design ]]; then
    printf '\n<requirements>\n'
    cat "$run_dir/requirements.md"
    printf '\n</requirements>\n'
  fi
  printf '\n<design>\n'
  cat "$run_dir/design.md"
  printf '\n</design>\n'
} >"$run_dir/prompt.md.tmp"

echo "$source" >"$run_dir/source.txt"
echo "$scope" >"$run_dir/scope.txt"
mv "$run_dir/prompt.md.tmp" "$run_dir/prompt.md"

echo "範囲: $scope"
echo "プロンプト: $run_dir/prompt.md"
