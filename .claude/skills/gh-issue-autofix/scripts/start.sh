#!/usr/bin/env bash
# Issue の着手を確保し、作業用の worktree を用意する。メインの checkout のブランチと作業ツリーには触れない。
#
# 使い方: start.sh --new <Issue の番号>     # 新しく着手する
#         start.sh --resume <Issue の番号>  # claude/issue-<番号> の続きから再開する
#   --new は、fetch した origin の既定ブランチの先頭から claude/issue-<番号> を作り、
#   「リモートにまだ存在しないときだけ」の条件で push して着手を確保する（存在すれば着手済みで止める）。
#   worktree は <メインの checkout>/.claude/worktrees/issue-<番号> に置き、git で追跡しない .env* をコピーする。
#   依存フォルダは、ロックファイルがメインの checkout の作業ツリーと同じときだけメインの checkout へリンクする。
#   違うときはリンクせず、前に張ったリンクも外す（worktree にインストールし直す）。
# 終了コード: 0 = 用意できた、1 = エラー（ネットワーク・権限など、環境の問題。--new で着手を確保したあとなら「着手は確保済み」と出す）
#   2 = 止める。出力の先頭で区分する:
#     claimed:  別のセッションが着手済み
#     busy:     その Issue の worktree に未コミットの変更がある（作業中の可能性）
#     conflict: その Issue に固有の問題（ローカルのブランチに独自のコミット、分岐、worktree の置き場所の衝突、
#               メインの checkout でそのブランチを開いている）
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
BASE_REF="origin/$DEFAULT_BRANCH"
# フォルダが消えた worktree の登録を片付ける
git worktree prune

existing=$(worktree_of "$BRANCH")
# メインの checkout の作業ツリーは使わない（使う人が作業している場所なので、ブランチを進めたり片付けたりしない）
[[ $existing != "$MAIN" ]] ||
  stop "conflict: メインの checkout（$MAIN）で $BRANCH を開いています。メインの checkout を別のブランチに切り替えてから実行し直してください。"
[[ -z $existing || -d $existing ]] || stop "conflict: $BRANCH の worktree（$existing）の登録がありますが、フォルダがありません。"
# 同じマシンの別のセッションが作業中の worktree には入らない
if [[ -n $existing && -n $(git -C "$existing" status --porcelain) ]]; then
  stop "busy: #$NUMBER の worktree（$existing）に未コミットの変更があります。別のセッションが作業中の可能性があるので止めます。前のセッションが終わっているなら、変更をコミットするか捨ててから実行し直してください。"
fi

# worktree の置き場所の衝突は、着手を確保する前に確かめる
[[ -n $existing || ! -e $WORKTREE ]] || stop "conflict: $WORKTREE がすでにあり、$BRANCH の worktree ではありません。不要なら消してから実行し直してください。"

remote=$(remote_sha "$BRANCH")
if [[ $MODE == new ]]; then
  [[ -z $remote ]] || stop "claimed: #$NUMBER は別のセッションが着手済みです（リモートに $BRANCH があります）。"
  created=false
  if git show-ref -q --verify "$REF"; then
    # 前回 push の前に止まったものだけ使い直す。独自のコミットがあるブランチは公開しない
    git merge-base --is-ancestor "$REF" "$BASE_REF" ||
      stop "conflict: ローカルの $BRANCH に $BASE_REF にないコミットがあります。続きから進めるなら --resume にするか、内容を確かめてから消すか別の名前にしてください。"
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
    [[ -z $(remote_sha "$BRANCH") ]] || stop "claimed: #$NUMBER は別のセッションが着手済みです（リモートに $BRANCH ができました）。"
    ! $created || git branch -q -D "$BRANCH" 2>/dev/null || true
    die "$BRANCH を push できません（権限・ブランチの保護・ネットワークを確かめてください）。
$out"
  fi
  # これより後の失敗では、確保した着手を呼び出し元が release.sh で取り消せるように知らせる
  trap 'rc=$?; ((rc == 0)) || echo "着手は確保済み: この実行がリモートに $BRANCH を作りました（release.sh $NUMBER で取り消せます）。" >&2' EXIT
  state="新規（$BASE_REF の先頭から）"
else
  if [[ -n $remote ]]; then
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
  elif git show-ref -q --verify "$REF"; then
    # 前回ローカルにだけコミットしてやめ、リモートの着手の印も消えたもの
    state="再開（ローカルの $BRANCH の続きから。リモートにはない）"
  else
    die "リモートにもローカルにも $BRANCH がないので再開できません。--new を使ってください。"
  fi
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

# --- 依存フォルダと .env* ---
link_names=" ${GH_ISSUE_AUTOFIX_LINK_DIRS:-node_modules .venv venv .bundle vendor} "
# ロックファイルがメインの checkout の作業ツリーと同じときだけ、メインの checkout の依存をリンクする
# （追加・削除・改行の変換は git diff が扱う。比べられないときは違うとみなす）
if git -C "$MAIN" diff --quiet --no-ext-diff "$REF" -- "${LOCKFILES[@]}" 2>/dev/null; then
  can_link=true
else
  can_link=false
fi

linked= unlinked= copied= skipped=
while IFS= read -r -d '' p; do
  p=${p%/}
  name=${p##*/}
  if [[ -d $MAIN/$p && $link_names == *" $name "* ]]; then
    if [[ -L $WORKTREE/$p && $(readlink "$WORKTREE/$p") == "$MAIN/$p" ]]; then
      # 前の実行で張ったリンク。違うときは外す（リンクそのものだけを消し、リンク先には触れない）
      if $can_link; then
        linked="$linked $p"
      else
        rm -- "$WORKTREE/$p"
        unlinked="$unlinked $p"
        skipped="$skipped $p"
      fi
      continue
    fi
    [[ ! -e $WORKTREE/$p && ! -L $WORKTREE/$p ]] || continue
    if $can_link; then
      mkdir -p "$(dirname "$WORKTREE/$p")"
      ln -s "$MAIN/$p" "$WORKTREE/$p"
      # .gitignore の「node_modules/」はリンクに効かないので、リンクそのものを除外する
      add_exclude "/$p"
      linked="$linked $p"
    else
      skipped="$skipped $p"
    fi
  elif [[ -f $MAIN/$p && $name == .env* && ! -e $WORKTREE/$p && ! -L $WORKTREE/$p ]]; then
    mkdir -p "$(dirname "$WORKTREE/$p")"
    cp -p "$MAIN/$p" "$WORKTREE/$p"
    # メインの checkout のブランチの .gitignore にだけある規則で無視されていることがあるので、worktree でも無視させる
    add_exclude "/$p"
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
ahead=$(git rev-list --count "$BASE_REF..$REF")
echo "- リポジトリ: $REPO"
echo "- 状態: $state"
echo "- worktree: $WORKTREE"
echo "- ブランチ: $BRANCH"
echo "- 既定ブランチ: $DEFAULT_BRANCH（基点: $(git log -1 --format='%h %s' "$base")）"
((ahead == 0)) || echo "- $BASE_REF にないコミット: $ahead 件"
echo "- リンクした依存フォルダ（書き込まない）:${linked:- なし}"
[[ -z $unlinked ]] || echo "- 外したリンク（ロックファイルがメインの checkout と違うため）:$unlinked"
if ! $can_link; then
  echo "- 注意: ロックファイルがメインの checkout の作業ツリーと違うので、依存をリンクしていません${skipped:+（対象:$skipped）}。worktree にプロジェクトの手順で、ロックファイルを変えない形（npm ci・pnpm install --frozen-lockfile・uv sync --locked など）でインストールしてください。"
fi
echo "- コピーした設定ファイル（コミットしない）:${copied:- なし}"
[[ -z $warn_deps ]] || echo "- 注意: $warn_deps があるので、リンクした依存はメインの checkout のコードを読み込みます。リンクを外し、worktree にプロジェクトの手順でインストールしてからテストしてください。"
if [[ -n $(git -C "$WORKTREE" status --porcelain) ]]; then
  echo "- 注意: 用意した直後の worktree に未コミットの変更があります。git status で確かめてください。"
fi
