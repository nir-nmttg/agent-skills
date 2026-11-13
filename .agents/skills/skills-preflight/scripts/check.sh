#!/usr/bin/env bash
# Codex スキルの基本環境を Markdown で表示する。環境やリンクは変更しない。
# 個別の前提・設定内容は SKILL.md の手順で確認する。不足があっても終了コードは 0。
set -euo pipefail

if (( $# > 0 )); then
  echo '使い方: bash scripts/check.sh' >&2
  exit 2
fi

repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
skills_dir="$repo_root/.agents/skills"
link_dir="$HOME/.agents/skills"

# パスに表の区切りや改行があっても Markdown を崩さない。
cell() {
  local value=$1
  value=${value//|/\&#124;}
  value=${value//$'\n'/ }
  value=${value//$'\r'/ }
  printf '%s' "$value"
}

printf '**Codex スキルの基本確認**\n\n'
printf '対象: %s\n\n' "$(cell "$skills_dir")"
printf '| 状態 | コマンド | 確認結果・用途 |\n'
printf '| --- | --- | --- |\n'
printf '| ✅ | `bash` | 実行中: %s（基本チェック用） |\n' "$BASH_VERSION"
if location=$(command -v git); then
  printf '| ✅ | `git` | %s |\n' "$(cell "$location")"
else
  printf '| ⚠️ | `git` | 見つかりません。履歴・差分の確認に使います |\n'
fi

cloudflare_skill="$link_dir/security-audit"
printf '\n| 状態 | 外部スキル | 確認結果 |\n'
printf '| --- | --- | --- |\n'
if [[ -L $cloudflare_skill && ! -e $cloudflare_skill ]]; then
  printf '| ⚠️ | Cloudflare `security-audit` | リンク先を参照できません（%s） |\n' "$(cell "$cloudflare_skill")"
elif [[ ! -e $cloudflare_skill ]]; then
  printf '| ⚠️ | Cloudflare `security-audit` | 標準の配置先にありません（%s） |\n' "$(cell "$cloudflare_skill")"
elif [[ ! -d $cloudflare_skill ]]; then
  printf '| ⚠️ | Cloudflare `security-audit` | 配置先がディレクトリではありません（%s） |\n' "$(cell "$cloudflare_skill")"
else
  missing_files=''
  for required_file in SKILL.md RECONNAISSANCE.md HUNTING.md ATTACK-CLASSES.md \
    VALIDATION-AND-REPORTING.md report-schema.json validate-coverage-ledger.cjs validate-findings.cjs; do
    path="$cloudflare_skill/$required_file"
    if [[ ! -f $path || ! -r $path || ! -s $path ]]; then
      missing_files+="${missing_files:+、}$required_file"
    fi
  done
  if [[ -n $missing_files ]]; then
    printf '| ⚠️ | Cloudflare `security-audit` | 配置が不完全です（%s）。不足・読み取り不可・空のファイル: %s |\n' \
      "$(cell "$cloudflare_skill")" "$missing_files"
  else
    printf '| ✅ | Cloudflare `security-audit` | 主要ファイルを参照可能（%s） |\n' "$(cell "$cloudflare_skill")"
  fi
fi

printf '\n| スキル | 定義 | UI・呼び出し設定 | ユーザー用リンク（任意） |\n'
printf '| --- | --- | --- | --- |\n'
count=0
for skill in "$skills_dir"/*/; do
  [[ -d $skill ]] || continue
  skill=${skill%/}
  name=${skill##*/}
  count=$((count + 1))
  definition='❌ SKILL.md がないか読み取れません'
  [[ ! -f $skill/SKILL.md || ! -r $skill/SKILL.md ]] || definition='✅ SKILL.md を参照可能'
  config='未配置（既定の呼び出し設定）'
  if [[ -e $skill/agents/openai.yaml || -L $skill/agents/openai.yaml ]]; then
    config='❌ openai.yaml を読み取れません'
    [[ ! -f $skill/agents/openai.yaml || ! -r $skill/agents/openai.yaml ]] || config='参照可能（内容は別途確認）'
  fi
  dest="$link_dir/$name"
  if [[ -L $dest && $dest -ef $skill ]]; then
    link='✅ このスキルにリンク済み'
  elif [[ -L $dest && ! -e $dest ]]; then
    link='⚠️ リンク切れ'
  elif [[ -L $dest ]]; then
    link='⚠️ 別の場所へのリンクあり'
  elif [[ -e $dest ]]; then
    link='⚠️ 同名のファイル・ディレクトリあり'
  else
    link='⚠️ 未リンク'
  fi
  printf '| %s | %s | %s | %s |\n' "$(cell "$name")" "$definition" "$config" "$link"
done
if (( count == 0 )); then
  printf '| — | ❌ Codex スキルが見つかりません | — | — |\n'
fi
printf '\n定義・設定の内容、スキル固有の依存関係、対象プロジェクトの検証環境は別途確認が必要です。\n'
printf 'リンクを反映する場合: `%s/scripts/link-skills.sh --codex`（worktree ではメインの checkout から実行）\n' "$(cell "$repo_root")"
exit 0
