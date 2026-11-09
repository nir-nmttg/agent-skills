#!/usr/bin/env bash
# Issue の着手を確保し、作業用の worktree を用意する。
#
# 使い方: start.sh --new <Issue の番号>     # 新しく着手する
#         start.sh --resume <Issue の番号>  # リモートの claude/issue-<番号> の続きから再開する
#   --new は、既定ブランチ（sync-base.sh で pull したローカルの既定ブランチ。なければ origin）の先頭から claude/issue-<番号> を作り、
#   「リモートにまだ存在しないときだけ」の条件で push して着手を確保する（存在すれば着手済みで止める）。
#   worktree は <メインの checkout>/.claude/worktrees/issue-<番号> に置き、
#   メインの checkout の依存フォルダをリンクし、git で追跡しない .env* をコピーする。
# 終了コード: 0 = 用意できた、1 = エラー（ネットワーク・権限など、環境の問題）
#   2 = 止める。出力の先頭で区分する:
#     claimed:  別の実行が着手済み
#     busy:     その Issue の worktree に未コミットの変更がある（作業中の可能性）
#     conflict: その Issue に固有の問題（ローカルのブランチに独自のコミット、分岐、worktree の置き場所の衝突）
set -euo pipefail
source "$(dirname "$0")/lib.sh"

(($# == 2)) && [[ $1 == --new || $1 == --resume ]] || die "使い方: start.sh --new|--resume <Issue の番号>"
MODE=${1#--}
NUMBER=$2
require_number "$NUMBER"
require_tools
load_repo

BRANCH=$(branch_name "$NUMBER")
REF="refs/heads/$BRANCH"
MAIN=$(main_root)
WORKTREE=$(worktree_path "$NUMBER")
fetch_default
# sync-base.sh で pull したローカルの既定ブランチから作り、メインの checkout と同じ版にする
if git show-ref -q --verify "refs/heads/$DEFAULT_BRANCH"; then
  BASE_REF="refs/heads/$DEFAULT_BRANCH"
else
  BASE_REF="origin/$DEFAULT_BRANCH"
fi
# フォルダが消えた worktree の登録を片付ける
git worktree prune

# 同じマシンの別のセッションが作業中の worktree には入らない
existing=$(worktree_of "$BRANCH")
[[ -z $existing || -d $existing ]] || stop "conflict: $BRANCH の worktree（$existing）の登録がありますが、フォルダがありません。"
if [[ -n $existing && -n $(git -C "$existing" status --porcelain) ]]; then
  stop "busy: #$NUMBER の worktree（$existing）に未コミットの変更があります。別のセッションが作業中の可能性があるので止めます。前のセッションが終わっているなら、変更をコミットするか捨ててから実行し直してください。"
fi

# worktree の置き場所の衝突は、着手を確保する前に確かめる
[[ -n $existing || ! -e $WORKTREE ]] || stop "conflict: $WORKTREE がすでにあり、$BRANCH の worktree ではありません。不要なら消してから実行し直してください。"

remote=$(remote_sha "$BRANCH")
if [[ $MODE == new ]]; then
  [[ -z $remote ]] || stop "claimed: #$NUMBER は別の実行が着手済みです（リモートに $BRANCH があります）。"
  created=false
  if git show-ref -q --verify "$REF"; then
    # 前回 push の前に止まったものだけ使い直す。独自のコミットがあるブランチは公開しない
    git merge-base --is-ancestor "$REF" "origin/$DEFAULT_BRANCH" ||
      stop "conflict: ローカルの $BRANCH に origin/$DEFAULT_BRANCH にないコミットがあります。内容を確かめてから、消すか別の名前にしてください。"
    [[ -z $existing ]] ||
      stop "conflict: ローカルの $BRANCH が worktree（$existing）で使われています。不要なら \`git worktree remove $existing\` で消してから実行し直してください。"
    git branch -q -f --no-track "$BRANCH" "$BASE_REF"
  else
    git branch -q --no-track "$BRANCH" "$BASE_REF"
    created=true
  fi
  # 期待値が空の --force-with-lease は、リモートに別の sha のブランチがあれば拒否される。
  # 同じ sha のブランチが先に作られていると「up to date」で成功するので、
  # porcelain の出力で「このプッシュで新しく作った（*）」ことまで確かめて、着手の確保とする
  out=$(git push --porcelain --no-verify --force-with-lease="$REF:" origin "$REF:$REF" 2>&1) && pushed=true || pushed=false
  if ! $pushed || ! grep -q "^\*	$REF:$REF	" <<<"$out"; then
    # 別のセッションが着手していれば、ローカルのブランチはそのセッションが使うかもしれないので残す
    [[ -z $(remote_sha "$BRANCH") ]] || stop "claimed: #$NUMBER は別の実行が着手済みです（リモートに $BRANCH ができました）。"
    ! $created || git branch -q -D "$BRANCH" 2>/dev/null || true
    die "$BRANCH を push できません（権限・ブランチの保護・ネットワークを確かめてください）。
$out"
  fi
  state="新規（${BASE_REF#refs/heads/} の先頭から）"
else
  [[ -n $remote ]] || die "リモートに $BRANCH がないので再開できません。--new を使ってください。"
  git fetch -q origin "+$REF:refs/remotes/origin/$BRANCH"
  if ! git show-ref -q --verify "$REF"; then
    git branch -q --no-track "$BRANCH" "origin/$BRANCH"
  else
    local_sha=$(git rev-parse "$REF")
    if git merge-base --is-ancestor "$remote" "$local_sha"; then
      : # ローカルが同じか先にある（前回 push しないで止めたコミットを含む）
    elif git merge-base --is-ancestor "$local_sha" "$remote"; then
      if [[ -n $existing ]]; then
        git -C "$existing" merge -q --ff-only "origin/$BRANCH"
      else
        git update-ref "$REF" "$remote" "$local_sha"
      fi
    else
      stop "conflict: ローカルの $BRANCH とリモートの $BRANCH が分岐しています。どちらを残すかを決めてから実行し直してください。"
    fi
  fi
  state="再開（リモートの $BRANCH の続きから）"
fi

# --- worktree ---
# info/exclude はすべての worktree に効く
exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
add_exclude() {
  mkdir -p "$(dirname "$exclude")"
  grep -qxF -- "$1" "$exclude" 2>/dev/null || echo "$1" >>"$exclude"
}
if [[ -n $existing ]]; then
  WORKTREE=$existing
else
  # worktree の置き場所を git status に出さない（Claude Code の EnterWorktree と同じ）
  add_exclude '.claude/worktrees/'
  mkdir -p "$(dirname "$WORKTREE")"
  git -c core.hooksPath=/dev/null worktree add -q "$WORKTREE" "$BRANCH"
fi
update_submodules "$WORKTREE" || die "worktree の submodule を更新できません。"

# 依存フォルダはリンクし（書き込まない）、.env* はコピーする
linked= copied=
link_names=" ${GH_ISSUE_AUTOFIX_LINK_DIRS:-node_modules .venv venv .bundle vendor} "
while IFS= read -r -d '' p; do
  p=${p%/}
  name=${p##*/}
  [[ ! -e $WORKTREE/$p && ! -L $WORKTREE/$p ]] || continue
  if [[ -d $MAIN/$p && $link_names == *" $name "* ]]; then
    mkdir -p "$(dirname "$WORKTREE/$p")"
    ln -s "$MAIN/$p" "$WORKTREE/$p"
    # .gitignore の「node_modules/」はリンクに効かないので、リンクそのものを除外する
    add_exclude "/$p"
    linked="$linked $p"
  elif [[ -f $MAIN/$p && $name == .env* ]]; then
    mkdir -p "$(dirname "$WORKTREE/$p")"
    cp -p "$MAIN/$p" "$WORKTREE/$p"
    copied="$copied $p"
  fi
done < <(git -C "$MAIN" ls-files -z --others --ignored --exclude-standard --directory)

# workspaces や editable install では、リンクした依存がメインの checkout のコードを読み込む
warn_deps=
if [[ -n $linked ]]; then
  if [[ -f $WORKTREE/pnpm-workspace.yaml ]] || { [[ -f $WORKTREE/package.json ]] && jq -e '.workspaces' "$WORKTREE/package.json" >/dev/null 2>&1; }; then
    warn_deps="JavaScript の workspaces"
  fi
  for v in .venv venv; do
    if [[ -L $WORKTREE/$v ]] && grep -qsF -- "$MAIN" "$MAIN/$v"/lib/python*/site-packages/*.pth "$MAIN/$v"/lib/python*/site-packages/__editable__*.py; then
      warn_deps="${warn_deps:+$warn_deps・}Python の editable install"
    fi
  done
  if [[ -L $WORKTREE/vendor && -f $WORKTREE/composer.json ]]; then
    warn_deps="${warn_deps:+$warn_deps・}PHP の Composer（autoload）"
  fi
fi

base=$(git merge-base "$BASE_REF" "$REF")
ahead=$(git rev-list --count "origin/$DEFAULT_BRANCH..$REF")
echo "- リポジトリ: $REPO"
echo "- 状態: $state"
echo "- worktree: $WORKTREE"
echo "- ブランチ: $BRANCH"
echo "- 既定ブランチ: $DEFAULT_BRANCH（基点: $(git log -1 --format='%h %s' "$base")）"
((ahead == 0)) || echo "- origin/$DEFAULT_BRANCH にないコミット: $ahead 件"
echo "- リンクした依存フォルダ（インストールしない）:${linked:- なし}"
echo "- コピーした設定ファイル（コミットしない）:${copied:- なし}"
# 再開したブランチの依存が既定ブランチと違えば、リンクした依存（既定ブランチの版）では合わない
# 前の実行で作ったリンクも含めて、メインの checkout を指す依存のリンクがあるか
has_links=false
[[ -z $linked ]] || has_links=true
if ! $has_links; then
  for name in $link_names; do
    if [[ -n $(find "$WORKTREE" -maxdepth 4 -type l -name "$name" 2>/dev/null | head -1) ]]; then has_links=true; break; fi
  done
fi
if $has_links && ! git diff --quiet "$BASE_REF" "$REF" -- "${LOCKFILES[@]}"; then
  echo "- 注意: このブランチのロックファイルが ${BASE_REF#refs/heads/} と違います。リンクした依存は ${BASE_REF#refs/heads/} の版なので、リンクを外し、worktree にプロジェクトの手順でインストールしてからテストしてください。"
fi
[[ -z $warn_deps ]] || echo "- 注意: $warn_deps があるので、リンクした依存はメインの checkout のコードを読み込みます。リンクを外し、worktree にプロジェクトの手順でインストールしてからテストしてください。"
if [[ -n $(git -C "$WORKTREE" status --porcelain) ]]; then
  echo "- 注意: worktree に未コミットの変更があります（前回の続き）。"
fi
