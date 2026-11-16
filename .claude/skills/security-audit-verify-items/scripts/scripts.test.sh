#!/usr/bin/env bash
# prepare.sh・guard.sh・cleanup.sh のテスト。一時的なリポジトリで実行フォルダを作り、終わったら消す。
#   bash scripts.test.sh
set -uo pipefail

dir=$(cd -P "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
fails=0
runs=()
cleanup() {
  for r in "${runs[@]}"; do bash "$dir/cleanup.sh" "$r" >/dev/null 2>&1; rm -rf "$r"; done
  rm -rf "$tmp"
}
trap cleanup EXIT

ok() { echo "ok - $1"; }
ng() { echo "not ok - $1"; fails=$((fails + 1)); }

# 対象リポジトリとサブエージェントのリンクを用意する
repo=$tmp/repo
git init -q "$repo"
mkdir -p "$repo/app" "$repo/sub"
echo "x" >"$repo/app/a.rb"
printf '.env*\nnode_modules/\n' >"$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q -m init
sha=$(git -C "$repo" rev-parse HEAD)
echo "KEY=secretvalue1" >"$repo/.env"
echo "KEY=secretvalue2" >"$repo/sub/.env.local"
echo "KEY=secretvalue3" >"$repo/.env.unignored-test"
printf '.env*\n!.env.unignored-test\nnode_modules/\n' >"$repo/.gitignore"
export CLAUDE_CONFIG_DIR=$tmp/claude
mkdir -p "$CLAUDE_CONFIG_DIR/agents" "$CLAUDE_CONFIG_DIR/skills"
touch "$CLAUDE_CONFIG_DIR/agents/security-audit-verifier.md"
ln -s "$(cd -P "$dir/.." && pwd)" "$CLAUDE_CONFIG_DIR/skills/security-audit-verify-items"

out=$(bash "$dir/prepare.sh" "$repo" "$sha") && ok "prepare.sh が成功する" || ng "prepare.sh が成功する: $out"
run=$(sed -n 's/^run //p' <<<"$out")
runs+=("$run")
[[ -f $run/worktree/app/a.rb && -d $run/items && -d $run/ledger && -d $run/issues ]] && ok "作業ツリーとフォルダができる" || ng "作業ツリーとフォルダができる"
[[ -f $run/refs/issue-templates.md && -f $run/refs/issue-sync.md ]] && ok "書式と反映の規則を写す" || ng "書式と反映の規則を写す"
[[ -f $run/worktree/.env && -f $run/worktree/sub/.env.local ]] && [[ -f $run/worktree/.env.unignored-test ]] && grep -q '^env_copied 3$' <<<"$out" && ok ".env* をコピーする（無視されていないものも）" || ng ".env* をコピーする: $out"
grep -q secretvalue <<<"$out" && ng "値を出力しない" || ok "値を出力しない"

hook() { jq -n --arg t "$1" --argjson i "$2" '{tool_name:$t, tool_input:$i, cwd:"/"}' | bash "$dir/guard.sh" 2>/dev/null; }
expect() { # expect <0|2> <説明> <ツール> <入力の JSON>
  hook "$3" "$4"
  local code=$?
  [[ $code == "$1" ]] && ok "$2" || ng "$2（終了コード $code）"
}
expect 0 "作業ツリーの中は読める" Read "{\"file_path\":\"$run/worktree/app/a.rb\"}"
expect 2 "対象リポジトリ（メインの checkout）は読めない" Read "{\"file_path\":\"$repo/app/a.rb\"}"
expect 0 "Grep は実行フォルダの中なら通す" Grep "{\"pattern\":\"x\",\"path\":\"$run/worktree\"}"
expect 2 "Grep の path の省略は止める" Grep '{"pattern":"x"}'
expect 0 "items/ には書ける" Write "{\"file_path\":\"$run/items/A03.json\",\"content\":\"{}\"}"
expect 2 "ledger/ には書けない" Write "{\"file_path\":\"$run/ledger/run.json\",\"content\":\"{}\"}"
expect 2 "作業ツリーには書けない" Write "{\"file_path\":\"$run/worktree/app/a.rb\",\"content\":\"y\"}"
expect 0 "実行フォルダへの cd で始まる Bash は通す" Bash "{\"command\":\"cd $run/worktree && git log --oneline -1\"}"
expect 2 "cd のない Bash は止める" Bash '{"command":"ls"}'
expect 2 "実行フォルダの外への cd は止める" Bash "{\"command\":\"cd $repo && ls\"}"
expect 2 "gh は止める" Bash "{\"command\":\"cd $run && gh issue view 1\"}"
expect 2 "状態を変える git は止める" Bash "{\"command\":\"cd $run/worktree && git checkout main\"}"
expect 2 "依存の導入は止める" Bash "{\"command\":\"cd $run/worktree && npm install\"}"
expect 2 "Edit は止める" Edit "{\"file_path\":\"$run/items/a\"}"
expect 2 ".. を含む Write は止める" Write "{\"file_path\":\"$run/items/x/../../ledger/start.json\",\"content\":\"{}\"}"
expect 2 ".. を含む Read は止める" Read "{\"file_path\":\"$run/x/../../../etc/hosts\"}"
expect 2 ".. を含む cd は止める" Bash "{\"command\":\"cd $run/worktree/../.. && ls\"}"

out2=$(bash "$dir/prepare.sh" "$repo" "$sha") || ng "2 回目の prepare.sh が成功する"
run2=$(sed -n 's/^run //p' <<<"$out2")
runs+=("$run2")
[[ ! -d $run/worktree && -d $run/ledger ]] && ok "新しく作ると、同じリポジトリの前の作業ツリーを消して記録は残す" || ng "前の作業ツリーを消して記録は残す"
expect 2 "作業ツリーを消した実行フォルダは使えない" Read "{\"file_path\":\"$run/items/A03.json\"}"

out3=$(bash "$dir/prepare.sh" --resume "$run") && [[ -f $run/worktree/app/a.rb ]] && ok "--resume で作業ツリーを作り直す" || ng "--resume で作業ツリーを作り直す: $out3"
rm -rf "$run/worktree"
bash "$dir/prepare.sh" --resume "$run" >/dev/null 2>&1 && [[ -f $run/worktree/app/a.rb ]] && ok "作業ツリーを手で消したあとも --resume で作り直す" || ng "作業ツリーを手で消したあとも --resume で作り直す"

bash "$dir/cleanup.sh" "$run2" >/dev/null && [[ ! -d $run2/worktree && -d $run2/items ]] && ok "cleanup.sh は作業ツリーだけを消す" || ng "cleanup.sh は作業ツリーだけを消す"
[[ -z $(git -C "$repo" worktree list --porcelain | grep -F "$run2/worktree") ]] && ok "対象リポジトリの登録も片付ける" || ng "対象リポジトリの登録も片付ける"

rm "$CLAUDE_CONFIG_DIR/skills/security-audit-verify-items"
bash "$dir/prepare.sh" "$repo" "$sha" >/dev/null 2>&1
[[ $? == 1 ]] && ok "スキルがリンクされていなければ止める" || ng "スキルがリンクされていなければ止める"
ln -s "$(cd -P "$dir/.." && pwd)" "$CLAUDE_CONFIG_DIR/skills/security-audit-verify-items"
rm "$CLAUDE_CONFIG_DIR/agents/security-audit-verifier.md"
bash "$dir/prepare.sh" "$repo" "$sha" >/dev/null 2>&1
[[ $? == 1 ]] && ok "サブエージェントがリンクされていなければ止める" || ng "サブエージェントがリンクされていなければ止める"

echo "fails: $fails"
[[ $fails == 0 ]]
