#!/usr/bin/env bash
# 監査対象のリポジトリを確定し、絶対パス・Git ルート・コミット・規模・結果の保存先を表示する（読み取り専用。何も作らない）。
#
# 使い方: resolve-targets.sh [--profile quick|standard|deep] [リポジトリ名またはパス...]
#   引数なし: 今のフォルダの下にある Git リポジトリすべて（今のフォルダがリポジトリの中ならそのリポジトリ）
#   名前: 今のフォルダの下にあるリポジトリのフォルダ名と完全一致で探す。同名が複数あればパスで指定する
#
# 保存先は このリポジトリ直下の artifacts/repo-security-audit/<名前>/run-<N>。
# それが対象リポジトリの中になる場合は ~/security-audit-skill/<名前>/run-<N> にする。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

profile=deep
names=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile) [[ $# -ge 2 ]] || usage; profile=$2; shift 2 ;;
    --profile=*) profile=${1#*=}; shift ;;
    -*) usage ;;
    *) names+=("$1"); shift ;;
  esac
done
[[ $profile =~ ^(quick|standard|deep)$ ]] || { echo "プロファイルは quick / standard / deep のどれかです。" >&2; exit 1; }

skill_dir=$(find_audit_skill) || {
  cat >&2 <<'EOF'
Cloudflare の security-audit スキルが見つかりません（~/.claude/skills・~/.agents/skills・~/.codex/skills を探しました）。
次のコマンドで入れてください:
  npx skills add cloudflare/security-audit-skill
別の場所にある場合は SECURITY_AUDIT_SKILL_DIR にそのディレクトリを指定してください。
EOF
  exit 1
}
command -v node >/dev/null || { echo "node が見つかりません。結果ファイルの検証に必要です。" >&2; exit 1; }

workspace=$(pwd -P)

# 今のフォルダの下にある Git リポジトリ（.git がディレクトリでもファイルでもよい）
candidates=$(
  {
    git -C "$workspace" rev-parse --show-toplevel 2>/dev/null || true
    find "$workspace" -maxdepth 5 \
      \( -name node_modules -o -name .venv -o -name venv -o -name vendor -o -name dist -o -name build -o -name .terraform -o -name Pods \) -prune \
      -o -name .git -print 2>/dev/null | sed 's|/\.git$||'
  } | while IFS= read -r d; do (cd -P "$d" && pwd); done | sort -u
)

die_with_candidates() {
  echo "$1" >&2
  if [[ -n $candidates ]]; then
    echo "今のフォルダ（${workspace}）の下にあるリポジトリ:" >&2
    sed "s|^|  |" <<<"$candidates" >&2
  else
    echo "今のフォルダ（${workspace}）の下に Git リポジトリがありません。" >&2
  fi
  exit 1
}

targets=""
if [[ ${#names[@]} -eq 0 ]]; then
  [[ -n $candidates ]] || die_with_candidates "監査対象が見つかりません。"
  # 他の候補の中にあるリポジトリ（サブモジュールなど）は親の監査に含まれるので外す
  targets=$(while IFS= read -r d; do
    nested=""
    while IFS= read -r p; do
      [[ $p != "$d" && $d == "$p"/* ]] && nested=1
    done <<<"$candidates"
    [[ -n $nested ]] || echo "$d"
  done <<<"$candidates")
else
  for n in "${names[@]}"; do
    if [[ -d $n ]]; then
      top=$(git -C "$n" rev-parse --show-toplevel 2>/dev/null) || die_with_candidates "Git リポジトリではありません: $n"
      targets+="$(cd -P "$top" && pwd)"$'\n'
      continue
    fi
    hits=$(awk -F/ -v n="$n" '$NF == n' <<<"$candidates")
    [[ -n $hits ]] || die_with_candidates "リポジトリが見つかりません: $n"
    if [[ $(wc -l <<<"$hits") -gt 1 ]]; then
      echo "「${n}」という名前のリポジトリが複数あります。パスで指定してください:" >&2
      sed "s|^|  |" <<<"$hits" >&2
      exit 1
    fi
    targets+="$hits"$'\n'
  done
  targets=$(sed '/^$/d' <<<"$targets" | awk '!seen[$0]++')
fi

dups=$(awk -F/ '{ print $NF }' <<<"$targets" | sort | uniq -d)
if [[ -n $dups ]]; then
  echo "同じ名前のリポジトリが複数含まれています（$(tr '\n' ' ' <<<"$dups")）。保存先が混ざるため、1 つずつパスで指定してください:" >&2
  sed "s|^|  |" <<<"$targets" >&2
  exit 1
fi

out_base=$(artifacts_root)
count=$(wc -l <<<"$targets" | tr -d ' ')

echo "Cloudflare security-audit スキル: $skill_dir"
echo "プロファイル: $profile"
echo "ワークスペース: $workspace"
echo "引数: $(if [[ ${#names[@]} -eq 0 ]]; then echo "なし（配下のリポジトリすべて）"; else echo "${names[*]}"; fi)"
echo "対象: $count 件"

i=0
while IFS= read -r t; do
  i=$((i + 1))
  name=${t##*/}
  top=$(git -C "$t" rev-parse --show-toplevel)
  head=$(git -C "$t" rev-parse HEAD 2>/dev/null || echo "（コミットなし）")
  branch=$(git -C "$t" branch --show-current 2>/dev/null || true)
  dirty=$(git -C "$t" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  # URL に埋め込まれた認証情報は表示しない
  remote=$(git -C "$t" remote get-url origin 2>/dev/null | sed -E 's#//[^/@]*@#//#' || true)
  files=$(git -C "$t" ls-files | wc -l | tr -d ' ')
  exts=$(git -C "$t" ls-files | sed -n 's/.*\.\([A-Za-z0-9]\{1,10\}\)$/\1/p' | sort | uniq -c | sort -rn | head -6 |
    awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }')

  root=$out_base
  [[ $root/ != "$t"/* ]] || root=$HOME/security-audit-skill
  dir="$root/$name"
  last=$(for r in "$dir"/run-*; do [[ -d $r ]] && echo "${r##*/run-}"; done | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  run_dir="$dir/run-$((${last:-0} + 1))"

  # 同じ対象を監査した以前の実行（run-metadata.json の target で判定）
  prior=$(for m in "$dir"/run-*/run-metadata.json; do
    [[ -f $m ]] || continue
    jq -r --arg t "$t" 'select(.target == $t) | "\(input_filename | sub("/run-metadata.json$"; ""))（\(.run_status // "状態不明")、\((.source_ref | if type == "object" then (.commit // .sha // tostring) else tostring end)[0:12])）"' "$m" 2>/dev/null || true
  done)

  echo
  echo "## $i. $name"
  echo "- パス: $t"
  echo "- Git ルート: $top$(if [[ $top != "$t" ]]; then echo "（⚠️ パスと一致しません）"; fi)"
  [[ -z $remote ]] || echo "- リモート: $remote"
  echo "- コミット: $head${branch:+（${branch}）}"
  echo "- 未コミットの変更: $(if [[ $dirty == 0 ]]; then echo "なし"; else echo "あり（$dirty ファイル）"; fi)"
  echo "- 規模: 追跡ファイル $files 件${exts:+（${exts}）}"
  echo "- 保存先: $run_dir$(if [[ $root != "$out_base" ]]; then echo "（artifacts が対象の中にあるため切り替え）"; fi)"
  if [[ -n $prior ]]; then
    echo "- 以前の実行:"
    sed 's/^/  - /' <<<"$prior"
  else
    echo "- 以前の実行: なし"
  fi
done <<<"$targets"
