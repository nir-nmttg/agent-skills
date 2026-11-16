#!/usr/bin/env bash
# security-audit-verify-items の実行フォルダと作業ツリーを用意する。
#   prepare.sh <対象のリポジトリ> <VERIFY_SHA>   新しい実行フォルダを作る
#   prepare.sh --resume <実行フォルダ>           続きから始める実行フォルダの作業ツリーを、控えた SHA で作り直す
# 出力: 「run <実行フォルダ>」「worktree <作業ツリー>」と、コピーした .env* の数（値は出さない）。
# 実行フォルダは artifacts/security-audit-verify-items/<実行 ID>/ に作り、worktree/ items/ ledger/ issues/ refs/ を置く。
# 新しく作るときは、同じ対象リポジトリのほかの実行フォルダの作業ツリーを消す（items/ ledger/ issues/ は残す）。
# 終了コード 1 は用意できない状態（理由を標準エラーに出す）、3 は引数の誤り。
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' "使い方: prepare.sh <対象のリポジトリ> <VERIFY_SHA> | prepare.sh --resume <実行フォルダ>" >&2; exit 3; }

source "$(dirname "$0")/lib.sh"

agent="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents/security-audit-verifier.md"
[[ -f $agent ]] || die "サブエージェント security-audit-verifier が見つかりません（$agent）。このスキル集の scripts/link-skills.sh --claude でリンクしてください"
command -v jq >/dev/null || die "jq がありません（Verifier の hook が使います）。brew install jq で入れてください"
# Verifier の hook はリンク経由でこのスキルの guard.sh を呼ぶので、リンクがこのスキル集を指していることを確かめる
self_dir=$(cd -P "$(dirname "$0")" && pwd)
linked=$(cd -P "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/security-audit-verify-items/scripts" 2>/dev/null && pwd) || linked=""
[[ $linked == "$self_dir" ]] || die "~/.claude/skills/security-audit-verify-items がこのスキル集を指していません。このスキル集の scripts/link-skills.sh --claude でリンクしてください"

root=$(runs_root) || die "実行フォルダの置き場所を決められません"
mkdir -p "$root"
root=$(cd -P "$root" && pwd)

copy_env() {
  local repo=$1 wt=$2 n=0 f
  while IFS= read -r -d '' f; do
    [[ $f == */node_modules/* || $f == node_modules/* ]] && continue
    mkdir -p "$wt/$(dirname "$f")"
    cp -p "$repo/$f" "$wt/$f"
    n=$((n + 1))
  done < <(git -C "$repo" ls-files -z --others -- ':(glob).env*' ':(glob)**/.env*')
  echo "env_copied $n"
}

make_worktree() {
  local run=$1 repo sha
  repo=$(cat "$run/repo")
  sha=$(cat "$run/sha")
  remove_worktree "$run"
  git -C "$repo" worktree prune
  git -C "$repo" -c core.hooksPath=/dev/null worktree add --detach "$run/worktree" "$sha" >/dev/null ||
    die "作業ツリーを作れません（$repo の $sha）"
  echo "run $run"
  echo "worktree $run/worktree"
  copy_env "$repo" "$run/worktree"
}

if [[ ${1-} == --resume ]]; then
  [[ $# -eq 2 ]] || usage
  run=$(cd -P "$2" 2>/dev/null && pwd) || die "実行フォルダがありません: $2"
  [[ $run == "$root"/* && -f $run/repo && -f $run/sha ]] || die "このスキルの実行フォルダではありません: $2"
  make_worktree "$run"
  exit 0
fi

[[ $# -eq 2 ]] || usage
repo=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || die "git リポジトリではありません: $1"
repo=$(cd -P "$repo" && pwd)
sha=$2
[[ $sha =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || usage
git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || die "コミットがありません: $sha（先に git fetch してください）"

# 同じ対象リポジトリのほかの実行フォルダの作業ツリーを片付ける
for old in "$root"/*/; do
  old=${old%/}
  [[ -f $old/repo && $(cat "$old/repo") == "$repo" ]] || continue
  remove_worktree "$old"
done

run="$root/$(date +%Y%m%d-%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
mkdir -p "$run/items" "$run/ledger" "$run/issues" "$run/refs"
# Verifier は実行フォルダの外を読めないので、書式と反映の規則を写しておく
refs="$(cd -P "$root/../.." && pwd)/.agents/skills/security-audit-sync-issues/references"
cp "$refs/issue-templates.md" "$refs/issue-sync.md" "$run/refs/" 2>/dev/null || die "参照ファイルがありません: $refs"
printf '%s\n' "$repo" >"$run/repo"
printf '%s\n' "$sha" >"$run/sha"
make_worktree "$run"
