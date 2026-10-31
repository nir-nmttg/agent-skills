#!/usr/bin/env bash
# このリポジトリのスキルを使うのに必要なコマンド・ログイン・外部スキルがそろっているかを確かめ、
# Markdown で結果と、足りないもののインストール方法を出力する。
#
# 使い方: check.sh
#   - 何も変更しない（インストールやログインはしない）
#   - 足りないものがあっても終了コードは 0（スキルの読み込み時に実行するため）
set -uo pipefail

repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
skills_dir="$repo_root/.claude/skills"
link_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"

has() { command -v "$1" >/dev/null 2>&1; }
ver() { "$@" 2>/dev/null | head -1 | sed 's/|/\\|/g'; }

rows=()      # 結果の表の行
missing=()   # 足りないもの（キー）
fixes=()     # 対処方法の行

# 結果を記録する: add <キー> <状態 ok|ng|warn> <項目> <詳細> <使うスキル> [対処方法]
add() {
  local key=$1 state=$2 item=$3 detail=$4 used_by=$5 fix=${6:-}
  local mark
  case $state in
    ok) mark='✅' ;;
    ng) mark='❌'; missing+=("$key") ;;
    warn) mark='⚠️' ;;
  esac
  rows+=("| $mark | $item | $detail | $used_by |")
  [[ $state == ok || -z $fix ]] || fixes+=("- **$item**: $fix")
}

# --- コマンド -----------------------------------------------------------------

# check_cmd <コマンド> <使うスキル> <インストール方法> [バージョンを出すコマンド...]
check_cmd() {
  local cmd=$1 used_by=$2 fix=$3
  shift 3
  if has "$cmd"; then
    local v=""
    (($# > 0)) && v=$(ver "$@")
    add "$cmd" ok "\`$cmd\`" "${v:-$(command -v "$cmd")}" "$used_by"
  else
    add "$cmd" ng "\`$cmd\`" "見つかりません" "$used_by" "$fix"
  fi
}

# Opus だけなら Codex なしで動くので、クロスレビューは Sol の分だけ Codex を使う
codex_users="codex-*, implementation-cross-review・design-cross-review（Sol）"

check_cmd git "ほぼすべて" "\`xcode-select --install\`（または \`brew install git\`）" git --version
check_cmd jq "ほぼすべて" "\`brew install jq\`" jq --version
check_cmd codex "$codex_users" "\`brew install --cask codex\` のあと \`codex login\`" codex --version
check_cmd perl "haiku-implementation, design-cross-review, implementation-cross-review, codex-risk-design-review, codex-risk-implementation-review" "\`brew install perl\`（macOS には標準で入っている）" perl -e 'print "perl $^V\n"'
check_cmd gh "gh-todo, gh-issue-overview, gh-pr-precheck, codex-verify-prompt（PR を渡すとき）" "\`brew install gh\` のあと \`gh auth login\`" gh --version
check_cmd python3 "gh-issue-overview" "\`xcode-select --install\`（または \`brew install python\`）" python3 --version
check_cmd curl "gh-issue-overview, gh-pr-precheck" "\`brew install curl\`"

# インストール方法は Homebrew 前提なので、足りないコマンドがあって Homebrew も無ければ先に入れてもらう
need_brew=false
if ((${#missing[@]} > 0)) && ! has brew; then
  need_brew=true
  rows+=("| ⚠️ | Homebrew | 見つかりません | インストールに使う |")
fi

# --- ログイン -----------------------------------------------------------------

if has codex; then
  if out=$(codex login status 2>&1); then
    add codex-login ok "Codex のログイン" "$(echo "$out" | head -1)" "$codex_users"
  else
    add codex-login ng "Codex のログイン" "未ログイン" "$codex_users" "\`codex login\`"
  fi
fi

if has gh; then
  if gh auth status >/dev/null 2>&1; then
    user=$(gh api user --jq .login 2>/dev/null || true)
    add gh-login ok "GitHub（gh）のログイン" "${user:+@$user}" "gh-todo, gh-issue-overview, gh-pr-precheck, codex-verify-prompt（PR を渡すとき）"
  else
    add gh-login ng "GitHub（gh）のログイン" "未ログイン" "gh-todo, gh-issue-overview, gh-pr-precheck, codex-verify-prompt（PR を渡すとき）" "\`gh auth login\`"
  fi
fi

# --- サブエージェントのリンク（haiku-implementation・haiku-check・レビューの 4 スキルに必須） ---------

agents_src="$repo_root/.claude/agents"
agents_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents"
agent_users="haiku-implementation, haiku-check, design-cross-review, implementation-cross-review, codex-risk-design-review, codex-risk-implementation-review"
unlinked_agents=()
for f in "$agents_src"/*.md; do
  [[ -f $f ]] || continue
  name=$(basename "$f")
  [[ -L $agents_dir/$name && $(readlink "$agents_dir/$name") == "$f" ]] || unlinked_agents+=("${name%.md}")
done
if ((${#unlinked_agents[@]} == 0)); then
  add agents-link ok "\`~/.claude/agents\` へのリンク" "すべてリンク済み" "$agent_users"
else
  add agents-link ng "\`~/.claude/agents\` へのリンク" "未リンク: ${unlinked_agents[*]}" "$agent_users" \
    "\`$repo_root/scripts/link-skills.sh --claude\`（初めて \`~/.claude/agents\` を作ったときは、新しいセッションで使う）"
fi
# haiku-implementer の hook は、ユーザー用のスキルのリンクから guard.sh を呼ぶ
if [[ -L $link_dir/haiku-implementation && $(readlink "$link_dir/haiku-implementation") == "$skills_dir/haiku-implementation" ]]; then
  add haiku-implementation-link ok "\`~/.claude/skills/haiku-implementation\` のリンク" "リンク済み" "haiku-implementation（hook の guard.sh）"
else
  add haiku-implementation-link ng "\`~/.claude/skills/haiku-implementation\` のリンク" "未リンク" "haiku-implementation（hook の guard.sh）" \
    "\`$repo_root/scripts/link-skills.sh --claude\`"
fi

# --- 他のフォルダから使うためのリンク（任意） --------------------------------

unlinked=()
for skill in "$skills_dir"/*/; do
  skill=${skill%/}
  name=$(basename "$skill")
  [[ -f $skill/SKILL.md ]] || continue
  [[ -L $link_dir/$name && $(readlink "$link_dir/$name") == "$skill" ]] || unlinked+=("$name")
done
if ((${#unlinked[@]} == 0)); then
  add links ok "\`~/.claude/skills\` へのリンク（任意）" "すべてリンク済み" "他のフォルダで使うとき"
else
  add links warn "\`~/.claude/skills\` へのリンク（任意）" "未リンク: ${unlinked[*]}" "他のフォルダで使うとき" \
    "（他のフォルダでも使うなら）\`$repo_root/scripts/link-skills.sh\`"
fi

# --- スキルごとの使える / 使えない ---------------------------------------------

skill_needs() {
  case $1 in
    codex-verify-prompt) echo "git jq" ;;
    codex-risk-design-review | codex-risk-implementation-review) echo "git jq perl codex codex-login agents-link" ;;
    design-cross-review) echo "perl agents-link" ;;
    implementation-cross-review) echo "git perl agents-link" ;;
    codex-*) echo "git jq codex codex-login" ;;
    haiku-implementation) echo "git jq perl agents-link haiku-implementation-link" ;;
    haiku-check) echo "git agents-link" ;;
    gh-todo) echo "jq gh gh-login" ;;
    gh-issue-overview) echo "jq gh gh-login python3 curl" ;;
    gh-pr-precheck) echo "jq gh gh-login curl" ;;
    *) echo "" ;;
  esac
}

# Sol を動かすのに必要なものがそろっているか
sol_ready() {
  local m
  for m in ${missing[@]+"${missing[@]}"}; do
    [[ $m == jq || $m == codex || $m == codex-login ]] && return 1
  done
  return 0
}

ready=()
blocked=()
for skill in "$skills_dir"/*/; do
  name=$(basename "$skill")
  [[ -f $skill/SKILL.md ]] || continue
  lack=()
  for need in $(skill_needs "$name"); do
    for m in ${missing[@]+"${missing[@]}"}; do
      [[ $m == "$need" ]] && lack+=("$need")
    done
  done
  if ((${#lack[@]} > 0)); then
    blocked+=("$name（${lack[*]}）")
  elif [[ $name == *-cross-review ]] && ! sol_ready; then
    ready+=("$name（Opus のみ）")
  else
    ready+=("$name")
  fi
done

# --- 出力 ---------------------------------------------------------------------

if ((${#missing[@]} == 0)); then
  echo "**すべてそろっています。** このリポジトリのスキルはすべて使えます。"
else
  echo "**足りないものが ${#missing[@]} 件あります。** 下の「対処方法」を実行してください。"
fi
echo
echo "| | 項目 | 状態 | 使うスキル |"
echo "| --- | --- | --- | --- |"
printf '%s\n' "${rows[@]}"
echo
echo "- 使える: ${ready[*]:-なし}"
((${#blocked[@]} == 0)) || echo "- 使えない: ${blocked[*]}"
if ((${#fixes[@]} > 0)); then
  echo
  echo "## 対処方法"
  echo
  ! $need_brew || echo "- **Homebrew**: 先に https://brew.sh の手順で入れる"
  printf '%s\n' "${fixes[@]}"
fi
exit 0
