#!/usr/bin/env bash
# prepare.sh で作った prompt.md を Codex CLI の GPT-6.1 Sol に読み取り専用でレビューさせ、review.md に保存する。
# 失敗したら、初回を含めて合計 3 回まで Sol で試す。Codex の呼び出しは implementation-cross-review の review.sh に任せる。
#
# 使い方: review.sh --effort <low|medium|high|xhigh|max> <実行フォルダ>
#   --effort  Codex の推論レベル。Claude の推論レベルをそのまま渡す（省略時は ${CLAUDE_EFFORT}、それもなければ high）
set -euo pipefail

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

effort="" run_dir=""
while (($#)); do
  case $1 in
    --effort) effort=${2:-}; shift 2 || usage ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリのスクリプトを使う
here=$(cd -P "$(dirname "$0")" && pwd)
base=$here/../../implementation-cross-review/scripts/review.sh
[[ -f $base ]] || { echo "エラー: implementation-cross-review スキルが見つかりません（${base}）" >&2; exit 1; }

attempts=3
for ((i = 1; i <= attempts; i++)); do
  if IMPLEMENTATION_CROSS_REVIEW_TITLE="Codex の設計適合レビュー（試行 $i/$attempts）" \
    bash "$base" --model gpt-6.1-sol ${effort:+--effort "$effort"} "$run_dir"; then
    exit 0
  fi
  echo "Sol の試行 $i/$attempts が失敗しました" >&2
  # 次の試行で上書きされるので、失敗のログを試行ごとに残す
  [[ ! -f $run_dir/codex.log ]] || cp "$run_dir/codex.log" "$run_dir/codex-attempt$i.log"
  ((i == attempts)) || sleep 10
done
echo "エラー: Sol は $attempts 回とも失敗しました（ログ: $run_dir/codex-attempt*.log）" >&2
exit 1
