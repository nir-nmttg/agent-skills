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

check_cmd git "ほぼすべて" "\`xcode-select --install\`（または \`brew install git\`）" git --version
check_cmd jq "ほぼすべて" "\`brew install jq\`" jq --version
check_cmd codex "codex-*" "\`brew install --cask codex\` のあと \`codex login\`" codex --version
check_cmd claude "opus-final-review" "\`brew install --cask claude-code\` のあと \`claude auth login\`" claude --version
check_cmd gh "gh-todo, gh-issue-overview, gh-pr-precheck, codex-verify-prompt（PR を渡すとき）" "\`brew install gh\` のあと \`gh auth login\`" gh --version
check_cmd python3 "gh-issue-overview" "\`xcode-select --install\`（または \`brew install python\`）" python3 --version
check_cmd curl "gh-issue-overview, gh-pr-precheck" "\`brew install curl\`"
check_cmd node "repo-security-audit" "\`brew install node\`" node --version

# インストール方法は Homebrew 前提なので、足りないコマンドがあって Homebrew も無ければ先に入れてもらう
need_brew=false
if ((${#missing[@]} > 0)) && ! has brew; then
  need_brew=true
  rows+=("| ⚠️ | Homebrew | 見つかりません | インストールに使う |")
fi

# --- ログイン -----------------------------------------------------------------

if has codex; then
  if out=$(codex login status 2>&1); then
    add codex-login ok "Codex のログイン" "$(echo "$out" | head -1)" "codex-*"
  else
    add codex-login ng "Codex のログイン" "未ログイン" "codex-*" "\`codex login\`"
  fi
fi

if has claude; then
  if out=$(claude auth status 2>/dev/null) && [[ $(jq -r '.loggedIn // false' <<<"$out" 2>/dev/null) == true ]]; then
    add claude-login ok "Claude のログイン" "$(jq -r '"\(.authMethod // "?")（\(.apiProvider // "?")）"' <<<"$out")" "opus-final-review"
  else
    add claude-login ng "Claude のログイン" "未ログイン" "opus-final-review" "\`claude auth login\`"
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

# --- 外部スキル ---------------------------------------------------------------

# repo-security-audit/scripts/lib.sh の find_audit_skill と同じ場所を探す
audit_dir=""
for d in ${SECURITY_AUDIT_SKILL_DIR:-} ~/.claude/skills/security-audit ~/.agents/skills/security-audit ~/.codex/skills/security-audit; do
  if [[ -f $d/SKILL.md && -f $d/validate-findings.cjs ]]; then
    audit_dir=$d
    break
  fi
done
if [[ -n $audit_dir ]]; then
  add security-audit ok "Cloudflare security-audit スキル" "${audit_dir/#$HOME/~}" "repo-security-audit"
else
  add security-audit ng "Cloudflare security-audit スキル" "見つかりません" "repo-security-audit" \
    "\`npx skills add cloudflare/security-audit-skill\`"
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
    codex-*) echo "git jq codex codex-login" ;;
    opus-final-review) echo "git jq claude claude-login" ;;
    parallel-tasks) echo "git jq" ;;
    gh-todo) echo "jq gh gh-login" ;;
    gh-issue-overview) echo "jq gh gh-login python3 curl" ;;
    gh-pr-precheck) echo "jq gh gh-login curl" ;;
    repo-security-audit) echo "git jq node security-audit" ;;
    *) echo "" ;;
  esac
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
  if ((${#lack[@]} == 0)); then ready+=("$name"); else blocked+=("$name（${lack[*]}）"); fi
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
