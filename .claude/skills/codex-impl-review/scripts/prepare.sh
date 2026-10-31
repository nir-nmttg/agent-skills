#!/usr/bin/env bash
# 作業フォルダの git の変更を取り出し、要件と合わせて、レビュアーに読ませる prompt.md を作る。
# Sol（review.sh）と Opus（opus-final-reviewer）は、ここで作った同じ prompt.md を読む。
#
# 使い方: prepare.sh [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] <実行フォルダ>
#   --cd           レビューするリポジトリ（既定: 今のフォルダ）
#   --base         <ref> から分岐して以降の変更（コミット済み＋未コミット）をレビューする
#   --commit       1 つのコミットだけをレビューする（当時のソースを <実行フォルダ>/tree に展開して読ませる）
#   --uncommitted  未コミットの変更（ステージ済み・未ステージ・未追跡）だけをレビューする
#   範囲を指定しなければ、既定ブランチ（origin/HEAD、なければ main / master）からの変更をすべてレビューする。
#
# 指示書、<実行フォルダ>/requirements.md（Claude が書いた要件）、差分、コードを読む場所、作業場所のルートの
# CLAUDE.md・.claude/CLAUDE.md・AGENTS.md を prompt.md にまとめる。サブエージェントは omitClaudeMd で
# ユーザー用・親フォルダの CLAUDE.md を読まないので、プロジェクトの指示はここで渡す。
# 実行に使う source.txt・scope.txt も残す。失敗したときは prompt.md を残さない。
#
# 環境変数 CODEX_IMPL_REVIEW_PROMPT で指示書を、CODEX_IMPL_REVIEW_INPUT で入力（requirements / context）を
# 変えられる（codex-risk-impl-review が使う）。
set -euo pipefail

usage() { sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

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

prompt_file=${CODEX_IMPL_REVIEW_PROMPT:-$(dirname "$0")/../assets/review-prompt.md}
input=${CODEX_IMPL_REVIEW_INPUT:-requirements}
case $input in
  requirements | context) ;;
  *) echo "エラー: 入力 '$input' には対応していません（requirements / context）" >&2; exit 1 ;;
esac

[[ -d $run_dir ]] || { echo "エラー: 実行フォルダ $run_dir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
# 途中で失敗したときに、前回の入力でレビューしないよう先に消す
rm -rf "$run_dir/prompt.md" "$run_dir/prompt.md.tmp" "$run_dir/source.txt" "$run_dir/scope.txt" "$run_dir/tree"

# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
[[ -s $run_dir/$input.md ]] || { echo "エラー: $run_dir/$input.md がないか空です" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
toplevel=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
workdir=$toplevel
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }

g() { git -C "$workdir" "$@"; }

# レビューする範囲を決め、差分を diff.patch に書き出す。source はレビュアーが周辺のコードを読む場所
untracked=() source=$workdir
if [[ $mode == commit ]]; then
  sha=$(g rev-parse -q --verify "$target^{commit}") || { echo "エラー: コミット '$target' が見つかりません" >&2; exit 1; }
  scope="コミット $(g log -1 --format='%h %s' "$sha")"
  # コミットメッセージには作成者の説明が入るので、Sol と Opus には件名だけを渡す（Astra は実装の説明も読む）
  if [[ $input == context ]]; then
    commits=$(g log -1 --format='%h %s%n%n%b' "$sha")
  else
    commits=$(g log -1 --format='%h %s' "$sha")
  fi
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
  # HEAD でも未コミットの変更が混ざらないよう、当時のソースを展開する。
  # git archive は export-ignore / export-subst で中身が欠けたり変わったりするので、一時的なインデックスから取り出す
  mkdir -p "$source"
  idx=$(mktemp "${TMPDIR:-/tmp}/codex-impl-review-index.XXXXXX")
  GIT_INDEX_FILE=$idx g read-tree "$sha"
  GIT_INDEX_FILE=$idx GIT_LFS_SKIP_SMUDGE=1 g checkout-index -a -f --prefix="$source/"
  rm -f "$idx"
fi
files=$(grep -c '^diff --git ' "$run_dir/diff.patch" || true)
lines=$(grep -E '^[+-]' "$run_dir/diff.patch" | grep -cvE '^(\+\+\+|---) ' || true)

# 大きすぎる差分はプロンプトに埋め込まず、diff.patch を読ませる
max_bytes=200000
size=$(wc -c <"$run_dir/diff.patch" | tr -d ' ')

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
  printf '\n<%s>\n' "$input"
  cat "$run_dir/$input.md"
  printf '\n</%s>\n\n<diff>\n' "$input"
  if ((size <= max_bytes)); then
    cat "$run_dir/diff.patch"
  else
    echo "差分が大きい（${size} バイト）ため埋め込んでいません。$run_dir/diff.patch を区切りながら読んでください。"
  fi
  printf '</diff>\n'
} >"$run_dir/prompt.md.tmp"

echo "$source" >"$run_dir/source.txt"
echo "${scope}（$files ファイル、$lines 行）" >"$run_dir/scope.txt"
mv "$run_dir/prompt.md.tmp" "$run_dir/prompt.md"

echo "範囲: ${scope}（$files ファイル、$lines 行）"
echo "コードを読む場所: $source"
echo "プロンプト: $run_dir/prompt.md"
