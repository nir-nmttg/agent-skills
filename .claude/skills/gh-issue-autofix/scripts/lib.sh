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
    stop "origin（$REPO）は fork です。fork の checkout は対象外なので、元のリポジトリの checkout で実行してください。"
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

# このスキルの状態（ロック・依存のインストールの記録・前回の結果）の置き場所。
# git が管理しない共通の .git の中に置き、どの worktree から実行しても同じ場所にする
# 改名前の gh-issue-auto-pr の置き場所があれば、移さずに必ずそちらを使う（ロック・PR の Auto-fix の記録などを、どの版から実行しても共有する）
state_dir() {
  local d
  d=$(state_dir_path)
  mkdir -p "$d"
  echo "$d"
}

# state_dir と同じ場所を、フォルダを作らずに返す（読むだけの確認に使う）。引数があれば、そのフォルダのリポジトリについて
state_dir_path() {
  local common d
  common=$(git ${1:+-C "$1"} rev-parse --path-format=absolute --git-common-dir)
  d=$common/gh-issue-autofix
  if [[ -d $common/gh-issue-auto-pr ]]; then d=$common/gh-issue-auto-pr; fi
  echo "$d"
}

# 時間の上限を付けて実行する（macOS に timeout はないので perl の alarm。子プロセスごと止める）。
# 時間切れは終了コード 124。自分が TERM・INT で止められたときも、子のプロセスグループごと止める
with_limit() {
  local sec=$1
  shift
  perl -e '
    my $sec = shift;
    my $pid = fork // die "fork: $!";
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or die "exec: $!" }
    my $stop = sub { my $code = shift; kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; exit $code };
    local $SIG{ALRM} = sub { $stop->(124) };
    local $SIG{TERM} = sub { $stop->(143) };
    local $SIG{INT} = sub { $stop->(130) };
    alarm $sec;
    waitpid($pid, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$sec" "$@"
}

# 理由を 1 行・200 文字（バイトではなく文字）に切る
one_line() { grep -v '^[[:space:]]*$' | head -1 | perl -CSD -ne 'chomp; print substr($_, 0, 200)' || true; }

# 親ディレクトリのモードの記録の置き場所（このスキル集のリポジトリの artifacts/gh-issue-autofix/parents/<ハッシュ>）。
# 親ディレクトリには .git がないので、スクリプトの実体のパスからこのスキル集のリポジトリを特定して置く。フォルダを作る
# 改名前の gh-issue-auto-pr の置き場所があれば、移さずにそちらを使う（前回の結果・起動の記録を引き継ぐ）
parent_state_dir() {
  local real root d old
  real=$(cd -P "$1" 2>/dev/null && pwd) || die "親ディレクトリが見つかりません: $1"
  root=$(git -C "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel) ||
    die "このスキル集のリポジトリを特定できません。"
  d=$root/artifacts/gh-issue-autofix/parents/$(printf '%s' "$real" | git hash-object --stdin)
  old=$root/artifacts/gh-issue-auto-pr/parents/${d##*/}
  if [[ -d $old ]]; then d=$old; fi
  mkdir -p "$d"
  printf '%s\n' "$real" >"$d/path"
  echo "$d"
}

# 親ディレクトリのモードで、リポジトリごとの記録のフォルダ名（owner/name の / を __ にする）
repo_key() { sed 's#/#__#' <<<"$1"; }
