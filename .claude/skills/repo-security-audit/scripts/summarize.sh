#!/usr/bin/env bash
# 監査結果（run フォルダ）を検証し、確定した問題・未検証事項・未調査領域・保存先を日本語の Markdown にまとめる。
#
# 使い方: summarize.sh <run フォルダ>...
#   複数渡すと、先頭にリポジトリごとの件数の表をつける。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
[[ $# -gt 0 ]] || usage
skill_dir=$(find_audit_skill) || { echo "Cloudflare の security-audit スキルが見つかりません。" >&2; exit 1; }

MAX_ROWS=40

# 表のセルに入れられるように改行と | を潰す
jq_cell='def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");'
# 未調査領域: 終わっていない・調べられなかった・範囲外の単位と、未解決のまま残った候補
jq_gaps='def gaps: [.[] | select((.status | IN("planned", "in_progress", "blocked", "deferred", "out_of_scope"))
  or (.status == "candidate" and (.unresolved | length) > 0))];'

json_or_empty() { if [[ -s $1 ]] && jq -e 'type == "array"' "$1" >/dev/null 2>&1; then cat "$1"; else echo '[]'; fi; }

validate() {
  local script=$1 file=$2 out
  if [[ ! -f $file ]]; then
    echo "❌ ファイルなし"
  elif out=$(node "$skill_dir/$script" "$file" 2>&1); then
    echo "✅"
  else
    echo "❌ $(head -3 <<<"$out" | tr '\n' ' ' | cut -c1-200)"
  fi
}

overview=""
details=""
for run in "$@"; do
  run=$(cd -P "$run" 2>/dev/null && pwd) || { echo "run フォルダがありません: $run" >&2; exit 1; }
  meta=$(cat "$run/run-metadata.json" 2>/dev/null || echo '{}')
  findings=$(json_or_empty "$run/findings.json")
  ledger=$(json_or_empty "$run/coverage-ledger.json")
  repo=$(jq -r '.repo // empty' <<<"$meta"); repo=${repo:-$(basename "$(dirname "$run")")}
  label="${repo}（${run##*/}）"
  status=$(jq -r '.run_status // "不明"' <<<"$meta")

  counts=$(jq -r '
    def sev($s): [.[] | select(.verdict == "confirmed" and .severity.overall_severity == $s)] | length;
    [sev("critical"), sev("high"), sev("medium"), sev("low"), sev("informational"),
     ([.[] | select(.verdict == "needs_validation")] | length)] | @tsv' <<<"$findings")
  gaps=$(jq "$jq_gaps"' gaps | length' <<<"$ledger")
  overview+="| $label | $status | $(tr '\t' '|' <<<"$counts" | sed 's/|/ | /g') | $gaps |"$'\n'

  details+=$(
    echo
    echo "## $label"
    echo
    jq -r '"- 対象: \(.target // "不明") @ \(.source_ref | if type == "object" then (.commit // .sha // tostring) elif . == null then "不明" else tostring end)",
           "- プロファイル: \(.profile // "不明") / 状態: \(.run_status // "不明")\(if .incomplete_reason then "（\(.incomplete_reason)）" else "" end)"' <<<"$meta"
    echo "- 検証: findings.json $(validate validate-findings.cjs "$run/findings.json") / coverage-ledger.json $(validate validate-coverage-ledger.cjs "$run/coverage-ledger.json")"
    jq -r '"- カバレッジ: 全 \(length) 単位（" + (group_by(.status) | map("\(.[0].status) \(length)") | join(" / ")) + "）"' <<<"$ledger"

    echo
    echo "### 確定した問題"
    echo
    jq -r "$jq_cell"' [.[] | select(.verdict == "confirmed")]
      | sort_by({critical: 0, high: 1, medium: 2, low: 3, informational: 4}[.severity.overall_severity])
      | if length == 0 then "なし" else
          "| 深刻度 | 内容 | 場所 | fingerprint |", "| --- | --- | --- | --- |",
          (.[] | ((.trace | map(select(.kind == "sink")) | first) // .trace[0]) as $loc
            | "| \(.severity.overall_severity) | \(.title | cell) | `\($loc.file):\($loc.line)` | `\(.fingerprint)` |")
        end' <<<"$findings"

    echo
    echo "### 未検証事項（needs_validation）"
    echo
    jq -r "$jq_cell"' [.[] | select(.verdict == "needs_validation")]
      | if length == 0 then "なし" else
          "| 内容 | 確かめられなかったこと | fingerprint |", "| --- | --- | --- |",
          (.[] | "| \(.title | cell) | \(.blockers | join(" / ") | cell) | `\(.fingerprint)` |")
        end' <<<"$findings"

    echo
    echo "### 未調査領域"
    echo
    [[ -f $run/coverage-ledger.json ]] || echo "coverage-ledger.json がないため不明（監査が途中で止まった可能性があります）"
    jq -r --argjson max "$MAX_ROWS" --argjson has_ledger "$([[ -f $run/coverage-ledger.json ]] && echo true || echo false)" "$jq_cell$jq_gaps"' gaps
      | if length == 0 then (if $has_ledger then "なし" else empty end) else
          "| 状態 | 入口 / 境界 | 攻撃の種類 | 理由 |", "| --- | --- | --- | --- |",
          (.[:$max][] | "| \(.status) | \(.surface | cell) / \(.boundary | cell) | \(.attack_class | cell) | \(.unresolved | join(" / ") | cell) |"),
          (if length > $max then "", "…ほか \(length - $max) 件（coverage-ledger.json を参照）" else empty end)
        end' <<<"$ledger"

    echo
    echo "### ファイル"
    echo
    echo "- フォルダ: $run"
    for f in REPORT.md FINDINGS-DETAIL.md NEEDS-VALIDATION.md findings.json coverage-ledger.json; do
      if [[ -f $run/$f ]]; then echo "- $f"; else echo "- ${f}（なし）"; fi
    done
  )$'\n'
done

if [[ $# -gt 1 ]]; then
  echo "| リポジトリ | 状態 | critical | high | medium | low | info | 未検証 | 未調査 |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  printf '%s' "$overview"
fi
printf '%s' "$details"
