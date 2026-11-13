#!/usr/bin/env bash
# 整備を始める: 作業ツリーが整っているかを確かめ、実行フォルダと進捗ファイルを作ってから、今の HEAD から作業ブランチを切る。
#
# 使い方: start.sh [--cd <dir>] <slug>
#   --cd  対象のリポジトリ（既定: 今のフォルダ）
#   slug  整備の短い名前（英数字・ハイフン）。実行フォルダ名に使う
#
# 止まる条件（終了コード 1）: git リポジトリでない、未コミットの変更（未追跡を含む）がある、実行フォルダか作業ブランチ（codebase-cleanup/<日時>）を作れない。
# 保存先は $CODEBASE_CLEANUP_WORKFLOW_DIR（既定: このリポジトリ直下の artifacts/codebase-cleanup-workflow）/<日時>-<slug>.<乱数>/。
set -euo pipefail

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

target="" slug=""
while (($#)); do
  case $1 in
    --cd) target=${2:-}; [[ -n $target ]] || usage; shift 2 ;;
    -*) usage ;;
    *) [[ -z $slug ]] || usage; slug=$1; shift ;;
  esac
done
[[ $slug =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$ ]] || usage

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する（cd する前に $0 から求める）
repo_root=$(cd -P "$(dirname "$0")/../../../.." && pwd)

if [[ -n $target ]]; then
  cd "$target" || { echo "エラー: $target に移動できません" >&2; exit 1; }
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  { echo "エラー: git リポジトリではありません（工程ごとのコミットとクロスレビューに git が要ります）" >&2; exit 1; }
top=$(git rev-parse --show-toplevel)
cd "$top"

changes=$(git status --porcelain --untracked-files=all)
if [[ -n $changes ]]; then
  echo "エラー: 未コミットの変更があります。コミットするか退避してから始めてください（整備のコミットと混ざるのを防ぐため）" >&2
  printf '%s\n' "$changes" | head -20 >&2
  exit 1
fi

start_sha=$(git rev-parse HEAD)
orig_branch=$(git branch --show-current)
stamp=$(date +%Y%m%d-%H%M%S)
branch="codebase-cleanup/$stamp"
n=2
while git show-ref --verify --quiet "refs/heads/$branch"; do
  branch="codebase-cleanup/$stamp-$n"
  n=$((n + 1))
done

# 記録を先に作り、失敗したらブランチを切り替えずに終える
root=${CODEBASE_CLEANUP_WORKFLOW_DIR:-$repo_root/artifacts/codebase-cleanup-workflow}
mkdir -p "$root"
# 同時に動かしても別のフォルダになるよう、原子的に作る
dir=$(mktemp -d "$root/$stamp-$slug.XXXXXX")

cat >"$dir/progress.md" <<EOF
# 整備の進捗

- 対象: \`$top\`
- 元のブランチ: \`${orig_branch:-（detached HEAD）}\`
- 作業ブランチ: \`$branch\`
- 開始時の SHA: \`$start_sha\`

## 依頼の範囲

（対象のパス・範囲、行う工程、時間やトークンの上限。再開しても、行わない工程は行わない）

## 変更前のチェック（基準）

（haiku-check の結果: 実行したコマンドごとに、成功・既存の失敗・実行不能）

## 工程

| 工程 | 状態 | 工程開始時の SHA | コミット | レビューの実行フォルダ | メモ |
| --- | --- | --- | --- | --- | --- |
| 1 design-alignment-refactor | 未着手 | | | | |
| 2 code-structure-refactor | 未着手 | | | | |
| 3 test-suite-refactor | 未着手 | | | | |
| 4 code-order-refactor | 未着手 | | | | |
| 5 docs-align-with-code | 未着手 | | | | |

## 保留・未探索

EOF

if ! git switch --quiet -c "$branch"; then
  # post-checkout hook の失敗では、切り替わったうえで失敗が返る。記録は残して止める
  if [[ $(git branch --show-current) == "$branch" ]]; then
    echo "エラー: 作業ブランチ $branch に切り替えたが、git の hook が失敗しました。記録は $dir にあります" >&2
    exit 1
  fi
  rm -rf "$dir"
  echo "エラー: 作業ブランチ $branch を作れません" >&2
  exit 1
fi

echo "対象: $top"
echo "作業ブランチ: $branch（元: ${orig_branch:-detached HEAD}）"
echo "開始時の SHA: $start_sha"
echo "実行フォルダ: $dir"
echo "進捗: $dir/progress.md"
echo "探索のまとめ: $dir/exploration.md"
