#!/usr/bin/env bash
# メインの checkout を既定ブランチに戻して pull し、依存の入れ直しが要るかを出す。
#
# 使い方: sync-base.sh                  # 既定ブランチに戻って pull する
#         sync-base.sh --deps-installed # 依存を入れ直せたことを記録する（メインの checkout が変わっていれば止める）
#   未コミットの変更があるとき、ローカルの既定ブランチに origin にないコミットがあるときは止める（終了コード 2）。
#   ロックファイルが、前回依存のインストールに成功したときと違えば「依存の入れ直し: 必要」と出す。
#   hook（husky の自動インストールなど）は動かさない。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

MODE=sync
case ${1:-} in
  "") ;;
  --deps-installed) MODE=mark ;;
  *) die "使い方: sync-base.sh [--deps-installed]" ;;
esac

require_tools
load_repo
MAIN=$(main_root)
[[ $(git rev-parse --show-toplevel) == "$MAIN" ]] ||
  stop "メインの checkout（$MAIN）で実行していません。スケジュールタスクのフォルダをメインの checkout にし、Worktree の設定をオフにしてください。"
cd "$MAIN"

# ロックファイルの内容（パスと blob）のハッシュ
deps_hash() {
  git ls-files -s -- "${LOCKFILES[@]}" | git hash-object --stdin
}
DEPS_RECORD=$(state_dir)/deps-installed

if [[ $MODE == mark ]]; then
  # 入れ直しでロックファイルなどの追跡ファイルが変わったら、成功として記録しない（次の実行が止まるため）
  [[ -z $(git status --porcelain) ]] || stop "依存の入れ直しでメインの checkout のファイルが変わりました。ロックファイルを変えない形（npm ci・uv sync --locked・BUNDLE_FROZEN=true など）で入れ直してください。
$(git status --short | head -20)"
  deps_hash >"$DEPS_RECORD"
  echo "依存のインストールを記録しました。"
  exit 0
fi

[[ -z $(git status --porcelain) ]] || stop "メインの checkout に未コミットの変更があります。消さずに止めるので、確かめて片付けてください。
$(git status --short | head -20)"

git -c core.hooksPath=/dev/null fetch -q origin "+refs/heads/$DEFAULT_BRANCH:refs/remotes/origin/$DEFAULT_BRANCH" ||
  die "origin から $DEFAULT_BRANCH を取得できません。"
before=$(git rev-parse -q --verify "refs/heads/$DEFAULT_BRANCH" || true)
if git show-ref -q --verify "refs/heads/$DEFAULT_BRANCH"; then
  ahead=$(git rev-list --count "origin/$DEFAULT_BRANCH..refs/heads/$DEFAULT_BRANCH")
  ((ahead == 0)) || stop "ローカルの $DEFAULT_BRANCH に origin にないコミットが $ahead 件あります。消さずに止めるので、確かめて片付けてください。"
  [[ $(git symbolic-ref -q --short HEAD || true) == "$DEFAULT_BRANCH" ]] ||
    git -c core.hooksPath=/dev/null switch -q "$DEFAULT_BRANCH"
  git -c core.hooksPath=/dev/null pull -q --ff-only origin "$DEFAULT_BRANCH" ||
    die "$DEFAULT_BRANCH を pull できません。"
else
  git -c core.hooksPath=/dev/null switch -q --no-track -c "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
fi
update_submodules . || die "submodule を更新できません。"
after=$(git rev-parse HEAD)

if [[ -f $DEPS_RECORD && $(cat "$DEPS_RECORD") == "$(deps_hash)" ]]; then
  deps="不要（前回インストールに成功したときからロックファイルが変わっていない）"
elif [[ -z $(git ls-files -- "${LOCKFILES[@]}") ]]; then
  deps="不要（ロックファイルがない）"
else
  deps="必要（ロックファイルが前回のインストールのあとに変わったか、記録がない）"
fi

echo "- リポジトリ: $REPO"
echo "- メインの checkout: $MAIN"
echo "- 既定ブランチ: $DEFAULT_BRANCH（$(git log -1 --format='%h %s' "$after")）"
if [[ -n $before && $before != "$after" ]]; then
  echo "- 更新: ${before:0:7} → ${after:0:7}"
else
  echo "- 更新: なし"
fi
echo "- 依存の入れ直し: $deps"
