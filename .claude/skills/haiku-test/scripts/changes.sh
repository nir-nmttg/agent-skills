#!/usr/bin/env bash
# テストの実行の前後で作業ツリーの内容を比べ、テストの実行で変わったファイルを見つける。
#
# 使い方: changes.sh new [--cd <dir>]   実行フォルダ（ログの保存先）を作り、今の状態を記録する
#         changes.sh snap <実行フォルダ>  再実行の前に、今の状態を記録し直す
#         changes.sh check <実行フォルダ> 記録した状態と比べ、変わったファイルがあれば差分を保存して知らせる
#
# 状態は未コミット・未追跡を含み（.gitignore 対象は除く）、本物のインデックスに触れずに記録する。
# git リポジトリでないフォルダでは、実行フォルダだけを作り、変わったファイルは確かめられないと知らせる。
# 保存先は $HAIKU_TEST_DIR（既定: このリポジトリ直下の artifacts/haiku-test）/<日時>-<リポジトリ名>/。
set -euo pipefail

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

# snapshot <dir>  作業ツリーの状態をツリーとして記録し、そのツリー ID を出力する
snapshot() {
  local dir=$1 idx real
  idx=$(mktemp "${TMPDIR:-/tmp}/haiku-test-index.XXXXXX")
  real=$(git -C "$dir" rev-parse --path-format=absolute --git-path index)
  if [[ -f $real ]]; then cp "$real" "$idx"; else rm -f "$idx"; fi
  GIT_INDEX_FILE=$idx git -C "$dir" add -A -- .
  GIT_INDEX_FILE=$idx git -C "$dir" write-tree
  rm -f "$idx"
}

cmd=${1:-}
(($#)) && shift
case $cmd in
  new)
    workdir=$PWD
    [[ ${1:-} == --cd ]] && { workdir=${2:-}; [[ -n $workdir ]] || usage; shift 2; }
    (($# == 0)) || usage
    [[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
    is_git=1
    top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) && workdir=$top || { is_git=""; workdir=$(cd -P "$workdir" && pwd); }
    # ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
    repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)
    run_dir="${HAIKU_TEST_DIR:-$repo_root/artifacts/haiku-test}/$(date +%Y%m%d-%H%M%S)-$(basename "$workdir")"
    mkdir -p "$run_dir"
    echo "$workdir" >"$run_dir/repo"
    echo "作業場所: $workdir"
    echo "ログの保存先: $run_dir"
    if [[ -n $is_git ]]; then
      snapshot "$workdir" >"$run_dir/before-tree"
    else
      echo "注意: git リポジトリではないので、テストの実行で変わったファイルは確かめられません"
    fi
    ;;
  snap | check)
    (($# == 1)) || usage
    run_dir=$1
    [[ -f $run_dir/repo ]] || { echo "エラー: $run_dir は changes.sh new で作った実行フォルダではありません" >&2; exit 1; }
    workdir=$(<"$run_dir/repo")
    [[ -f $run_dir/before-tree ]] || { echo "git リポジトリではないので、変わったファイルは確かめられません"; exit 0; }
    if [[ $cmd == snap ]]; then
      snapshot "$workdir" >"$run_dir/before-tree"
      echo "今の状態を記録しました: $workdir"
      exit 0
    fi
    before=$(<"$run_dir/before-tree")
    after=$(snapshot "$workdir")
    if [[ $before == "$after" ]]; then
      echo "テストの実行で変わったファイル: なし"
    else
      n=1
      while [[ -e $run_dir/changes-$n.patch ]]; do n=$((n + 1)); done
      git -C "$workdir" diff --binary "$before" "$after" >"$run_dir/changes-$n.patch"
      echo "注意: テストの実行中に追跡対象のファイルが変わりました: $(git -C "$workdir" diff --shortstat "$before" "$after" | sed 's/^ *//')"
      git -C "$workdir" diff --stat "$before" "$after"
      echo "差分: $run_dir/changes-$n.patch"
    fi
    ;;
  *) usage ;;
esac
