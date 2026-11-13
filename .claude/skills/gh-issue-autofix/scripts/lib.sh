# gh-issue-autofix のスクリプトが共有する処理。実行せず、source して使う。
# macOS 標準の bash 3.2 で動くように書く。

die() {
  echo "$*" >&2
  exit 1
}

# 止める理由（対象がない・断る・着手済み）を出して、終了コード 2 で終える
stop() {
  echo "$*"
  exit 2
}

require_tools() {
  local c
  for c in git gh jq; do
    command -v "$c" >/dev/null 2>&1 || die "$c がありません。\`brew install $c\` で入れてください。"
  done
  gh auth status >/dev/null 2>&1 || die "gh が未ログインです。\`gh auth login\` を実行してください。"
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "git リポジトリの中で実行してください。"
  git remote get-url origin >/dev/null 2>&1 || die "remote の origin がありません。"
}

# GitHub の URL（https / ssh）から owner/name を小文字で取り出す。GitHub でなければ空
github_repo_of() {
  sed -nE 's#^(https?://([^/@]*@)?(www\.)?github\.com/|ssh://([^/@]*@)?github\.com/|[^/@]*@github\.com:)([^/]+)/([^/]+)$#\5/\6#p' <<<"$1" |
    sed -E 's#\.git$##' | tr '[:upper:]' '[:lower:]'
}

# origin の GitHub リポジトリを REPO（owner/name）と DEFAULT_BRANCH に入れる。
# Issue の取得・PR の作成・push はすべてこのリポジトリに対して行う（gh の既定のリポジトリには頼らない）。
# URL には認証情報が含まれることがあるので、メッセージには出さない。
load_repo() {
  local origin info url
  origin=$(git remote get-url origin)
  info=$(gh repo view "$origin" --json nameWithOwner,defaultBranchRef,isFork 2>/dev/null) ||
    die "origin の GitHub リポジトリを取得できません（\`git remote -v\` と gh のログインを確かめてください）。"
  REPO=$(jq -r .nameWithOwner <<<"$info")
  DEFAULT_BRANCH=$(jq -r '.defaultBranchRef.name // empty' <<<"$info")
  [[ -n $DEFAULT_BRANCH ]] || die "$REPO の既定ブランチを取得できません。"
  [[ $(jq -r .isFork <<<"$info") == false ]] ||
    stop "origin（${REPO}）は fork です。fork の checkout は対象外なので、元のリポジトリの checkout で実行してください。"
  # push 先（pushurl を含む）がすべて同じリポジトリを指すこと
  while IFS= read -r url; do
    [[ $(github_repo_of "$url") == "$(tr '[:upper:]' '[:lower:]' <<<"$REPO")" ]] ||
      stop "origin の push 先が $REPO と違うリポジトリを指しています（\`git remote get-url --push --all origin\` で確かめてください）。"
  done < <(git remote get-url --push --all origin)
}

require_number() {
  [[ ${1:-} =~ ^[1-9][0-9]*$ ]] || die "Issue の番号を数字で指定してください: ${1:-（なし）}"
}

branch_name() {
  echo "claude/issue-$1"
}

# メインの checkout のルート（worktree の中から実行しても同じ場所を返す。submodule でも正しい）
main_root() {
  git worktree list --porcelain | sed -n '1s/^worktree //p'
}

worktree_path() {
  echo "$(main_root)/.claude/worktrees/issue-$1"
}

# ブランチを checkout している worktree のパス（なければ空）
worktree_of() {
  git worktree list --porcelain | awk -v b="branch refs/heads/$1" '/^worktree /{p=substr($0,10)} $0==b{print p}'
}

# リモートのブランチの sha（なければ空）
remote_sha() {
  git ls-remote --heads origin "refs/heads/$1" | cut -f1
}

fetch_default() {
  git fetch -q origin "+refs/heads/$DEFAULT_BRANCH:refs/remotes/origin/$DEFAULT_BRANCH" ||
    die "origin から $DEFAULT_BRANCH を取得できません。"
}

# 依存を決めるロックファイル（git の pathspec）
LOCKFILES=('*package-lock.json' '*npm-shrinkwrap.json' '*pnpm-lock.yaml' '*yarn.lock' '*bun.lock' '*bun.lockb'
  '*uv.lock' '*poetry.lock' '*Pipfile.lock' '*requirements*.txt' '*Gemfile.lock' '*composer.lock' '*go.sum' '*Cargo.lock')

# submodule があれば、作業ツリーに合わせて更新する（hook は動かさない）
update_submodules() {
  [[ -f ${1:-.}/.gitmodules ]] || return 0
  git -C "${1:-.}" -c core.hooksPath=/dev/null submodule update -q --init --recursive
}
