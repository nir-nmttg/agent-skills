#!/usr/bin/env bash
# prepare.sh で作った worktree に Haiku が実装した結果を、もとの作業フォルダに反映して worktree を片づける。
#
# 使い方: apply.sh [--discard] <実行フォルダ>...
#   --discard  反映せずに worktree を捨てる
#
# 反映は、worktree を切った時点の状態をベースにしたファイルごとの 3-way マージで行う。
# その後に作業フォルダで変わったファイルとも混ざり、重なった箇所は競合マーカーを残す。
# 本物のインデックス（ステージ）やブランチには触れない。反映した差分は <実行フォルダ>/applied.patch に保存する。
# 競合が 1 つでもあれば終了コード 2 で終わる。
set -euo pipefail

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
source "$(dirname "$0")/lib.sh"

discard=""
[[ ${1:-} == --discard ]] && { discard=1; shift; }
(($#)) || usage

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# blob <dir> <tree> <path> <出力先>  ツリーの中のファイルを書き出す。なければ失敗
blob() { git -C "$1" cat-file -e "$2:$3" 2>/dev/null && git -C "$1" cat-file blob "$2:$3" >"$4"; }

# same <a> <b>  2 つのファイル（なければ「ない」同士）が同じか
same() {
  if [[ -e $1 || -L $1 ]]; then [[ -e $2 || -L $2 ]] && cmp -s "$1" "$2"; else [[ ! -e $2 && ! -L $2 ]]; fi
}

# put <src> <dst> <mode>  Haiku 側の内容をそのまま書く（mode は ls-tree のもの）
put() {
  mkdir -p "$(dirname "$2")"
  rm -f "$2"
  if [[ $3 == 120000 ]]; then ln -s "$(<"$1")" "$2"; else cp "$1" "$2"; fi
  if [[ $3 == 100755 ]]; then chmod +x "$2"; elif [[ $3 == 100644 ]]; then chmod -x "$2"; fi
}

overall=0
for run_dir in "$@"; do
  run_dir=$(cd -P "$run_dir" && pwd)
  wt=$run_dir/worktree
  echo "## $(basename "$run_dir")"
  if [[ ! -f $run_dir/repo || ! -d $wt ]]; then
    echo "- worktree がありません（prepare.sh で準備していないか、反映・破棄済み）"
    overall=1
    continue
  fi
  repo=$(<"$run_dir/repo")

  if [[ -n $discard ]]; then
    git -C "$repo" worktree remove --force "$wt"
    echo "- 反映せずに worktree を破棄しました"
    continue
  fi

  base=$(<"$run_dir/base-tree")
  final=$(snapshot "$wt" "$run_dir/linked")
  git -C "$wt" diff --binary "$base" "$final" >"$run_dir/applied.patch"

  taken=() merged=() conflicts=() skipped=()
  while IFS= read -r -d '' st && IFS= read -r -d '' path; do
    ours=$repo/$path b=$tmp/base t=$tmp/theirs
    rm -f "$b" "$t"
    blob "$wt" "$base" "$path" "$b" || true
    if [[ $st == D ]]; then
      if [[ ! -e $ours && ! -L $ours ]]; then skipped+=("$path")
      elif same "$ours" "$b"; then rm -f "$ours"; taken+=("${path}（削除）")
      else conflicts+=("$path: Haiku は削除したが、作業フォルダでも変更されている（作業フォルダの内容を残した）")
      fi
      continue
    fi
    mode=$(git -C "$wt" ls-tree "$final" -- "$path" | cut -d' ' -f1)
    blob "$wt" "$final" "$path" "$t"
    if same "$ours" "$t"; then skipped+=("$path")
    elif same "$ours" "$b"; then put "$t" "$ours" "$mode"; taken+=("$path")
    elif [[ ! -e $ours && ! -L $ours ]]; then
      conflicts+=("$path: 作業フォルダで削除されている（Haiku 版を $path.haiku に置いた）")
      put "$t" "$ours.haiku" "$mode"
    elif [[ $mode == 120000 || -L $ours || $(git -C "$wt" diff --numstat "$base" "$final" -- "$path" | cut -f1) == - ]]; then
      conflicts+=("$path: マージできない種類のファイル（Haiku 版を $path.haiku に置いた）")
      put "$t" "$ours.haiku" "$mode"
    else
      [[ -f $b ]] || : >"$b"
      rc=0
      git merge-file -L 作業フォルダ -L ベース -L Haiku "$ours" "$b" "$t" || rc=$?
      if ((rc == 0)); then merged+=("$path")
      elif ((rc > 0 && rc < 128)); then conflicts+=("$path: $rc か所の競合（マーカーを残した）")
      else
        conflicts+=("$path: マージできない（Haiku 版を $path.haiku に置いた）")
        put "$t" "$ours.haiku" "$mode"
      fi
    fi
  done < <(git -C "$wt" diff -z --name-status --no-renames "$base" "$final")

  echo "- 反映: そのまま ${#taken[@]} ファイル、作業フォルダの変更とマージ ${#merged[@]} ファイル、反映済み ${#skipped[@]} ファイル"
  echo "- 差分: $run_dir/applied.patch"
  ((${#merged[@]})) && printf -- '- マージ: %s\n' "${merged[@]}"
  if ((${#conflicts[@]})); then
    printf -- '- 競合: %s\n' "${conflicts[@]}"
    echo "- worktree は残しています: ${wt}（解消したら apply.sh --discard $run_dir で片づける）"
    overall=2
  else
    git -C "$repo" worktree remove --force "$wt"
    echo "- worktree を片づけました"
  fi
done
exit $overall
