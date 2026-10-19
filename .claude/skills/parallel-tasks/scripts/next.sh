#!/usr/bin/env bash
# 終わった作業と始めた作業を受け取り、依存がすべて終わっていて今すぐ始められる作業を出力する。
#
# 使い方: next.sh <計画フォルダ> [--started <id,...>] [<終わった作業の id>...]
#   --started  始めたがまだ終わっていない作業（出力から除く）
#
# 先に plan-check.sh で計画を確かめておく。すべて終わっていれば「すべて終わりました」と出力する。
set -euo pipefail

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

(($# >= 1)) || usage
dir=$(cd "$1" && pwd)
shift
started=""
if [[ ${1:-} == --started ]]; then
  [[ -n ${2:-} ]] || usage
  started=$2
  shift 2
fi
plan="$dir/plan.json"
[[ -f $plan ]] || { echo "plan.json がありません: $plan" >&2; exit 1; }

script_dir=$(cd -P "$(dirname "$0")" && pwd)

jq -r -L "$script_dir" --arg dir "$dir" --arg started "$started" '
  include "plan";
  $ARGS.positional as $done
  | ($started | split(",") | map(select(length > 0))) as $started
  | deps_map as $deps
  | (.tasks | map(.id)) as $ids
  | [.tasks[] | select(.id as $i | $done | index($i) | not)] as $rest
  | [$rest[] | select(.id as $i | $started | index($i) | not) | select(($deps[.id] - $done | length) == 0)] as $ready
  | [$rest[] | select(.id as $i | ($started | index($i) | not) and ($ready | map(.id) | index($i) | not))] as $waiting
  | ([$done[], $started[]] - $ids) as $unknown
  | (if ($unknown | length) > 0 then "計画にない id です: \($unknown | join("、"))", "" else empty end),
    (if ($rest | length) == 0 then "すべて終わりました"
     else
       "今すぐ始められる作業（\($ready | length) 本）:",
       (if ($ready | length) == 0 then "  なし（実行中の作業が終わるのを待つ）" else empty end),
       ($ready[] | "  \(.id)（\(.runner | runner_label)）: \(.title)\(if .runner == "self" then "" else " → \($dir)/briefs/\(.id).md" end)"),
       (if ($started | length) > 0 then "実行中: \($started | join("、"))" else empty end),
       (if ($waiting | length) > 0
        then "依存待ち: \($waiting | map("\(.id)（\($deps[.id] - $done | join("、")) 待ち）") | join("、"))"
        else empty end)
     end)
' "$plan" --args "$@" </dev/null
