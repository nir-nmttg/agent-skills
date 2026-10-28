#!/usr/bin/env bash
# 作業フォルダの git の変更を取り出し、要件と合わせて、opus-final-reviewer に読ませる prompt.md を作る。
#
# 使い方: prepare.sh [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] <実行フォルダ>
#   --cd           レビューするリポジトリ（既定: 今のフォルダ）
#   --base         <ref> から分岐して以降の変更（コミット済み＋未コミット）をレビューする
#   --commit       1 つのコミットだけをレビューする（当時のソースを <実行フォルダ>/tree に展開して読ませる）
#   --uncommitted  未コミットの変更（ステージ済み・未ステージ・未追跡）だけをレビューする
#   範囲を指定しなければ、既定ブランチ（origin/HEAD、なければ main / master）からの変更をすべてレビューする。
#
# <実行フォルダ>/requirements.md（Claude が書いた要件）と差分、コードを読む場所、作業場所のルートの
# CLAUDE.md・.claude/CLAUDE.md・AGENTS.md を prompt.md にまとめる。サブエージェントは omitClaudeMd で
# ユーザー用・親フォルダの CLAUDE.md を読まないので、プロジェクトの指示はここで渡す。
set -euo pipefail

usage() { sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

workdir=$PWD run_dir="" mode=auto target=""
while (($#)); do
  case $1 in
    --cd) workdir=${2:-}; shift 2 || usage ;;
    --base | --commit)
      [[ $mode == auto ]] || usage
      mode=${1#--}; target=${2:-}; [[ -n $target ]] || usage; shift 2 ;;
    --uncommitted) [[ $mode == auto ]] || usage; mode=uncommitted; shift ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

[[ -s $run_dir/requirements.md ]] || { echo "エラー: $run_dir/requirements.md がないか空です" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
toplevel=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
workdir=$toplevel
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }

g() { git -C "$workdir" "$@"; }

# レビューする範囲を決め、差分を diff.patch に書き出す。source はレビュアーが周辺のコードを読む場所
untracked=() source=$workdir
if [[ $mode == commit ]]; then
  sha=$(g rev-parse -q --verify "$target^{commit}") || { echo "エラー: コミット '$target' が見つかりません" >&2; exit 1; }
  scope="コミット $(g log -1 --format='%h %s' "$sha")"
  # コミットメッセージには作成者の説明が入るので、件名だけを渡す
  commits=$(g log -1 --format='%h %s' "$sha")
  # マージコミットは combined diff だと取り込んだ変更が出ないので、第一親との差分にする
  if g rev-parse -q --verify "$sha^1" >/dev/null; then
    stat=$(g diff --stat "$sha^1" "$sha")
    g diff "$sha^1" "$sha" >"$run_dir/diff.patch"
  else
    stat=$(g show --format= --stat "$sha")
    g show --format= --patch "$sha" >"$run_dir/diff.patch"
  fi
  source=$run_dir/tree
else
  if [[ $mode == uncommitted ]]; then
    from=$(g rev-parse HEAD)
    scope="未コミットの変更（HEAD $(g rev-parse --short HEAD) からの差分）"
  else
    if [[ $mode == auto ]]; then
      target=$(g symbolic-ref -q --short refs/remotes/origin/HEAD) ||
        for b in main master; do g rev-parse -q --verify "$b^{commit}" >/dev/null && { target=$b; break; }; done
      [[ -n $target ]] || { echo "エラー: 既定ブランチがわかりません。--base か --commit か --uncommitted で範囲を指定してください" >&2; exit 1; }
    fi
    g rev-parse -q --verify "$target^{commit}" >/dev/null || { echo "エラー: '$target' が見つかりません" >&2; exit 1; }
    from=$(g merge-base "$target" HEAD) || { echo "エラー: '$target' と HEAD の共通の祖先がありません" >&2; exit 1; }
    scope="$target から分岐して以降の変更（$(g rev-parse --short "$from") からの差分。未コミットの変更を含む）"
  fi
  commits=$(g log --format='%h %s' "$from..HEAD")
  stat=$(g diff --stat "$from")
  g diff "$from" >"$run_dir/diff.patch"
  while IFS= read -r -d '' f; do untracked+=("$f"); done < <(g ls-files -z --others --exclude-standard)
  for f in ${untracked[@]+"${untracked[@]}"}; do
    # --no-index は差分があると 1 で終わる。それ以外の失敗は取りこぼしになるので止める
    rc=0
    (cd "$workdir" && git diff --no-index -- /dev/null "$f" >>"$run_dir/diff.patch") || rc=$?
    ((rc <= 1)) || { echo "エラー: 未追跡ファイル '$f' の差分を作れませんでした" >&2; exit 1; }
  done
fi

if [[ ! -s $run_dir/diff.patch ]]; then
  echo "エラー: レビューする変更がありません（範囲: ${scope}）。--base / --commit / --uncommitted で範囲を指定してください" >&2
  exit 1
fi
if [[ $mode == commit ]]; then
  # レビュアーは git を使えないので、HEAD でも未コミットの変更が混ざらないよう、当時のソースを展開する。
  # git archive は export-ignore / export-subst で中身が欠けたり変わったりするので、一時的なインデックスから取り出す
  rm -rf "$source"
  mkdir -p "$source"
  idx=$(mktemp "${TMPDIR:-/tmp}/opus-final-review-index.XXXXXX")
  GIT_INDEX_FILE=$idx g read-tree "$sha"
  GIT_INDEX_FILE=$idx GIT_LFS_SKIP_SMUDGE=1 g checkout-index -a -f --prefix="$source/"
  rm -f "$idx"
fi
files=$(grep -c '^diff --git ' "$run_dir/diff.patch" || true)
lines=$(grep -E '^[+-]' "$run_dir/diff.patch" | grep -cvE '^(\+\+\+|---) ' || true)

# 大きすぎる差分はプロンプトに埋め込まず、diff.patch を Read で読ませる
max_bytes=200000
size=$(wc -c <"$run_dir/diff.patch" | tr -d ' ')

{
  echo "# 最終レビューの依頼"
  printf '\n<scope>\n'
  echo "リポジトリ: $workdir"
  echo "範囲: $scope"
  echo "コードを読む場所: $source"
  echo "差分のファイル: $run_dir/diff.patch"
  if [[ -n $commits ]]; then printf '\nコミット:\n%s\n' "$commits"; fi
  if [[ -n $stat ]]; then printf '\n変更ファイル:\n%s\n' "$stat"; fi
  if ((${#untracked[@]})); then printf '\n未追跡の新規ファイル:\n'; printf '%s\n' "${untracked[@]}"; fi
  printf '</scope>\n'
  # 同じ内容（CLAUDE.md が AGENTS.md へのリンクのときなど）は 1 回だけ渡す
  seen=" " source_real=$(cd -P "$source" && pwd)
  for f in CLAUDE.md .claude/CLAUDE.md AGENTS.md; do
    [[ -f $source/$f ]] || continue
    # リンクでリポジトリの外のファイル（秘密情報など）を取り込まないよう、実体がリポジトリの中のものだけを渡す
    real=$(perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); defined $r or exit 1; print $r' "$source/$f") &&
      [[ $real == "$source_real"/* ]] || { echo "注意: $f はリポジトリの外を指しているので渡しません" >&2; continue; }
    sum=$(cksum <"$source/$f" | tr ' ' -)
    [[ $seen != *" $sum "* ]] || continue
    seen+="$sum "
    printf '\n<project-instructions file="%s">\n' "$f"
    cat "$source/$f"
    printf '\n</project-instructions>\n'
  done
  printf '\n<requirements>\n'
  cat "$run_dir/requirements.md"
  printf '\n</requirements>\n\n<diff>\n'
  if ((size <= max_bytes)); then
    cat "$run_dir/diff.patch"
  else
    echo "差分が大きい（${size} バイト）ため埋め込んでいません。$run_dir/diff.patch を Read で区切りながら読んでください。"
  fi
  printf '</diff>\n'
} >"$run_dir/prompt.md"

echo "範囲: ${scope}（$files ファイル、$lines 行）"
echo "コードを読む場所: $source"
echo "プロンプト: $run_dir/prompt.md"
