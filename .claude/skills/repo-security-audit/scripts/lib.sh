# resolve-targets.sh と summarize.sh から source する共通処理。

# Cloudflare の security-audit スキルのディレクトリを探す
find_audit_skill() {
  local d
  for d in ${SECURITY_AUDIT_SKILL_DIR:-} ~/.claude/skills/security-audit ~/.agents/skills/security-audit ~/.codex/skills/security-audit; do
    if [[ -f $d/SKILL.md && -f $d/validate-findings.cjs ]]; then
      (cd -P "$d" && pwd)
      return 0
    fi
  done
  return 1
}

# 結果の保存先の親（~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリ直下に保存する）
artifacts_root() {
  local repo_root
  repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
  echo "$repo_root/artifacts/repo-security-audit"
}
