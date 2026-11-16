# security-audit-verify-items のスクリプトで共有する関数。source して使う。

# runs_root  実行フォルダを置く場所（このリポジトリ直下の artifacts/security-audit-verify-items）を出力する。
# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリを指す
runs_root() {
  local repo_root
  repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd) || return 1
  echo "$repo_root/artifacts/security-audit-verify-items"
}

# real_path <path>  実体のパスを出力する（存在しない末尾はそのままつなぐ）。相対パスは今のフォルダから
real_path() {
  local p=$1 rest="" r
  [[ $p == /* ]] || p=$PWD/$p
  while [[ ! -e $p && ! -L $p ]]; do
    rest=/${p##*/}$rest
    p=${p%/*}
    [[ -n $p ]] || p=/
  done
  r=$(perl -MCwd=realpath -e 'my $r = realpath($ARGV[0]); defined $r or exit 1; print $r' "$p") || return 1
  [[ $r == / ]] && r=""
  printf '%s%s\n' "$r" "$rest"
}

# remove_worktree <実行フォルダ>  実行フォルダの作業ツリーを消す（対象リポジトリの登録も片付ける）
remove_worktree() {
  local run=$1 repo
  [[ -d $run/worktree ]] || return 0
  repo=$(cat "$run/repo" 2>/dev/null) || repo=""
  if [[ -n $repo && -d $repo ]]; then
    git -C "$repo" worktree remove --force "$run/worktree" 2>/dev/null || rm -rf "$run/worktree"
    git -C "$repo" worktree prune 2>/dev/null || true
  else
    rm -rf "$run/worktree"
  fi
}
