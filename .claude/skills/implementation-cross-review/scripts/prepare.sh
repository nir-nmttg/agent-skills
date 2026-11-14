#!/usr/bin/env bash
# 作業フォルダの git の変更を取り出し、要件と合わせて、レビュアーに読ませる prompt.md を作る。
# Astra（review.sh）と Fable（fable-reviewer。Fable の代わりは opus-reviewer）は、ここで作った同じ prompt.md を読む。
#
# 使い方: prepare.sh [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] <実行フォルダ>
#   --cd           レビューするリポジトリ（既定: 今のフォルダ。確認のレビューでは前回のリポジトリ）
#   --base         <ref> から分岐して以降の変更（コミット済み＋未コミット）をレビューする
#   --commit       1 つのコミットだけをレビューする（当時のソースを <実行フォルダ>/tree に展開して読ませる）
#   --uncommitted  未コミットの変更（ステージ済み・未ステージ・未追跡）だけをレビューする
#   範囲を指定しなければ、既定ブランチ（origin/HEAD、なければ main / master）からの変更をすべてレビューする。
#   new-run.sh --followup で作った実行フォルダ（previous.txt がある）は確認のレビューにし、範囲は指定できない。
#
# 1 回目のレビュー: 指示書、<実行フォルダ>/requirements.md（Claude が書いた要件）、差分、コードを読む場所、作業場所の
# ルートの CLAUDE.md・.claude/CLAUDE.md・AGENTS.md を prompt.md にまとめる。サブエージェントは omitClaudeMd で
# ユーザー用・親フォルダの CLAUDE.md を読まないので、プロジェクトの指示はここで渡す。確認のレビューに備えて、
# 作業ツリーのスナップショット（snapshot.txt）・リポジトリ（repo.txt）・HEAD（head.txt）も残す。
# 確認のレビュー: 確認用の指示書、要件、<実行フォルダ>/fixes.md（直したことと決定済み）、前回のスナップショットから
# 今の作業ツリーまでの差分（fix.patch）を prompt.md にまとめる。
# 実行に使う source.txt・scope.txt も残す。失敗したときは prompt.md を残さない。
set -euo pipefail

usage() { sed -n '5,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

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

assets=$(dirname "$0")/../assets

[[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
# 途中で失敗したときに、前回の入力でレビューしないよう先に消す
rm -rf "$run_dir/prompt.md" "$run_dir/prompt.md.tmp" "$run_dir/source.txt" "$run_dir/scope.txt" "$run_dir/tree" \
  "$run_dir/snapshot.txt" "$run_dir/repo.txt" "$run_dir/head.txt" "$run_dir/fix.patch"

# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

followup=""
if [[ -e $run_dir/previous.txt ]]; then
  followup=1
  [[ $mode == auto ]] || { echo "エラー: 確認のレビューでは範囲（--base / --commit / --uncommitted）を指定できません" >&2; exit 1; }
  prev=$(cat "$run_dir/previous.txt")
  [[ -d $prev ]] || { echo "エラー: 前回の実行フォルダ $prev がありません" >&2; exit 1; }
  prev=$(cd -P "$prev" && pwd)
  [[ $prev != "$run_dir" ]] || { echo "エラー: 前回の実行フォルダが今回と同じです" >&2; exit 1; }
  for f in snapshot.txt repo.txt head.txt; do
    [[ -s $prev/$f ]] || { echo "エラー: 前回の $f がありません（前回のスナップショットを取れませんでした）。確認のレビューは使えないので、--followup を付けずに全体の差分でレビューしてください" >&2; exit 1; }
  done
  [[ -s $run_dir/fixes.md ]] || { echo "エラー: $run_dir/fixes.md がないか空です" >&2; exit 1; }
  # --cd を省いたら前回のリポジトリを使う（別の worktree の変更を、直したこととして読まないため）
  [[ -n $cd_given ]] || workdir=$(cat "$prev/repo.txt")
fi
prompt_file=$assets/review-prompt.md
[[ -z $followup ]] || prompt_file=$assets/followup-prompt.md

[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
[[ -s $run_dir/requirements.md ]] || { echo "エラー: $run_dir/requirements.md がないか空です" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
toplevel=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
workdir=$toplevel
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }

g() { git -C "$workdir" "$@"; }

# 大きすぎる差分はプロンプトに埋め込まず、ファイルを読ませる
max_bytes=200000

if [[ -n $followup ]]; then
  # 前回のスナップショットから今の作業ツリーまでの差分を fix.patch に書き出す（scope・commits・files・lines・size を設定する）
  collect_fix_diff "$workdir" "$prev" "$run_dir"

  {
    cat "$prompt_file"
    printf '\n\n<scope>\n'
    echo "リポジトリ: $workdir"
    echo "範囲: $scope"
    echo "コードを読む場所: $workdir"
    echo "修正の差分のファイル: $run_dir/fix.patch"
    if [[ -n $commits ]]; then printf '\n前回のレビューのあとのコミット:\n%s\n' "$commits"; fi
    printf '</scope>\n'
    print_project_instructions "$workdir"
    printf '\n<requirements>\n'
    cat "$run_dir/requirements.md"
    printf '\n</requirements>\n\n<fixes>\n'
    cat "$run_dir/fixes.md"
    printf '\n</fixes>\n\n<fix-diff>\n'
    if ((size <= max_bytes)); then
      cat "$run_dir/fix.patch"
    else
      echo "差分が大きい（${size} バイト）ため埋め込んでいません。$run_dir/fix.patch を区切りながら読んでください。"
    fi
    printf '</fix-diff>\n'
  } >"$run_dir/prompt.md.tmp"

  echo "$workdir" >"$run_dir/source.txt"
  echo "${scope}（修正 $files ファイル、$lines 行）" >"$run_dir/scope.txt"
  mv "$run_dir/prompt.md.tmp" "$run_dir/prompt.md"

  echo "範囲: ${scope}（修正 $files ファイル、$lines 行）"
  echo "コードを読む場所: $workdir"
  echo "プロンプト: $run_dir/prompt.md"
  exit 0
fi

# レビューする範囲を決め、差分を diff.patch に書き出す（scope・commits・stat・untracked・source・files・lines・size を設定する）
collect_diff "$workdir" "$run_dir" "$mode" "$target"

# 確認のレビューに備えて、今の作業ツリーを記録する（直したことは作業ツリーに入るので、--commit でも作業ツリーで取る）。
# 取れなくてもこのレビューは続ける（そのときの再レビューは、--followup を付けずに全体の差分で行う）
tree_id=$(snapshot "$workdir" 2>/dev/null) || { tree_id=""; echo "注意: 作業ツリーのスナップショットを取れませんでした。確認のレビューは使えません" >&2; }

{
  cat "$prompt_file"
  printf '\n\n<scope>\n'
  echo "リポジトリ: $workdir"
  echo "範囲: $scope"
  echo "コードを読む場所: $source"
  echo "差分のファイル: $run_dir/diff.patch"
  if [[ -n $commits ]]; then printf '\nコミット:\n%s\n' "$commits"; fi
  if [[ -n $stat ]]; then printf '\n変更ファイル:\n%s\n' "$stat"; fi
  if ((${#untracked[@]})); then printf '\n未追跡の新規ファイル:\n'; printf '%s\n' "${untracked[@]}"; fi
  printf '</scope>\n'
  print_project_instructions "$source"
  printf '\n<requirements>\n'
  cat "$run_dir/requirements.md"
  printf '\n</requirements>\n\n<diff>\n'
  if ((size <= max_bytes)); then
    cat "$run_dir/diff.patch"
  else
    echo "差分が大きい（${size} バイト）ため埋め込んでいません。$run_dir/diff.patch を区切りながら読んでください。"
  fi
  printf '</diff>\n'
} >"$run_dir/prompt.md.tmp"

echo "$source" >"$run_dir/source.txt"
echo "${scope}（$files ファイル、$lines 行）" >"$run_dir/scope.txt"
if [[ -n $tree_id ]]; then
  echo "$tree_id" >"$run_dir/snapshot.txt"
  echo "$workdir" >"$run_dir/repo.txt"
  g rev-parse HEAD >"$run_dir/head.txt"
fi
mv "$run_dir/prompt.md.tmp" "$run_dir/prompt.md"

echo "範囲: ${scope}（$files ファイル、$lines 行）"
echo "コードを読む場所: $source"
echo "プロンプト: $run_dir/prompt.md"
