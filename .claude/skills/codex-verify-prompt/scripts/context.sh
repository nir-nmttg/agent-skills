#!/usr/bin/env bash
# 動作確認の依頼プロンプトを作る材料（確かめる変更の概要・差分・ローカルで起動する手がかり）を Markdown で出力し、
# 差分を保存する。何も変更しない。
#
# 使い方: context.sh [PR の URL | owner/repo#番号]
#   PR を指定すると、PR の概要・本文・変更ファイル・コミット・PR が閉じる Issue を出す
#   省略すると、今のフォルダの作業中の変更（既定ブランチから分かれたあとのコミットと未コミットの変更）を出す
#   どちらでも、今のフォルダが対象のリポジトリなら、ローカルで起動する手がかりを出す
#
# 差分の保存先: このリポジトリ直下の artifacts/codex-verify-prompt/ の下
#   PR あり: <owner>/<repo>/pr-<番号>/<head の SHA 7 桁>.diff
#   PR なし: session/<リポジトリ名>/<ブランチ>-<YYYYMMDD-HHMMSS>.diff
set -euo pipefail

usage() { sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

owner="" repo="" number=""
if [[ -n ${1:-} ]]; then
  if [[ $1 =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+) ]] ||
     [[ $1 =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
    owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} number=${BASH_REMATCH[3]}
  else
    usage
  fi
fi

# ~/.claude/skills のシンボリックリンク経由で呼ばれても、リンク先のリポジトリに保存する
skills_repo=$(cd -P "$(dirname "$0")/../../../.." && pwd)
out_root="$skills_repo/artifacts/codex-verify-prompt"

lines() { awk 'END { print NR }' "$1"; }

# --- ローカルで起動する手がかり -----------------------------------------------------

launch_hints() {
  local root=$1 f found=0
  echo
  echo "## ローカルで起動する手がかり（\`$root\`）"
  echo

  if [[ -f $root/.claude/launch.json ]] && command -v jq >/dev/null 2>&1; then
    found=1
    echo "- \`.claude/launch.json\`（Claude のプレビュー用の起動設定）:"
    jq -r '.configurations[]? | "  - \(.name): `\(([.runtimeExecutable] + (.runtimeArgs // [])) | map(select(. != null)) | join(" "))`\(if .port then "（port \(.port)）" else "" end)\(if .url then "（\(.url)）" else "" end)"' \
      "$root/.claude/launch.json" 2>/dev/null || echo "  - （読めませんでした）"
  fi

  if [[ -f $root/package.json ]] && command -v jq >/dev/null 2>&1; then
    found=1
    local pm=npm
    [[ -f $root/pnpm-lock.yaml ]] && pm=pnpm
    [[ -f $root/yarn.lock ]] && pm=yarn
    [[ -f $root/bun.lockb || -f $root/bun.lock ]] && pm=bun
    echo "- \`package.json\` の scripts（パッケージマネージャー: $pm）:"
    jq -r '.scripts // {} | to_entries[:25][] | "  - \(.key): `\(.value)`"' "$root/package.json" 2>/dev/null || echo "  - （読めませんでした）"
  fi

  local others
  others=$(git -C "$root" ls-files -- '*/package.json' 2>/dev/null | grep -v node_modules | head -n 10 || true)
  if [[ -n $others ]]; then
    found=1
    echo "- サブフォルダの \`package.json\`（モノレポの可能性）:"
    sed 's/^/  - /' <<<"$others"
  fi

  if [[ -f $root/Makefile ]]; then
    found=1
    echo "- \`Makefile\` のターゲット: $(grep -oE '^[A-Za-z0-9_.-]+:' "$root/Makefile" | grep -v '^\.' | tr -d ':' | head -n 20 | sed 's/.*/`&`/' | paste -sd ' ' - || true)"
  fi

  for f in Procfile Procfile.dev; do
    if [[ -f $root/$f ]]; then
      found=1
      echo "- \`$f\`:"
      head -n 10 "$root/$f" | sed 's/^/  - `/; s/$/`/'
    fi
  done

  local present=()
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml bin/dev bin/setup manage.py Gemfile go.mod Cargo.toml pyproject.toml \
           .env.example .env.sample .env.local.example .env.development .nvmrc .node-version .tool-versions mise.toml .devcontainer/devcontainer.json; do
    [[ -e $root/$f ]] && present+=("\`$f\`")
  done
  if ((${#present[@]} > 0)); then
    found=1
    echo "- そのほかのファイル: ${present[*]}"
  fi

  for f in "$root"/README* "$root"/CONTRIBUTING* "$root"/docs/*{setup,development,getting-started,local}*; do
    [[ -f $f ]] || continue
    local heads
    heads=$(grep -niE '^#+ .*(setup|install|getting started|quick ?start|develop|running|local|run |起動|開発|環境構築|セットアップ|インストール|ローカル)' "$f" | head -n 15 || true)
    [[ -n $heads ]] || continue
    found=1
    echo "- \`${f#"$root"/}\` の起動に関係しそうな見出し（行番号: 見出し）:"
    sed 's/^/  - /' <<<"$heads"
  done

  ((found)) || echo "- 見つかりませんでした（README などを直接読む）"
}

# --- PR がないとき: 今のフォルダの作業中の変更 ----------------------------------------

if [[ -z $number ]]; then
  if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "今のフォルダ（$PWD）は git リポジトリではありません。動作確認する変更のあるフォルダで実行してください。" >&2
    exit 1
  fi
  branch=$(git branch --show-current)
  head=$(git rev-parse HEAD)

  base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -z $base ]]; then
    for b in origin/main origin/master main master; do
      if git rev-parse --verify --quiet "$b" >/dev/null; then base=$b; break; fi
    done
  fi
  from=HEAD
  # 既定ブランチの上で作業していても、push していないコミットを含めるため、リモートの既定ブランチとの分かれ目を基準にする
  if [[ -n $base ]] && mb=$(git merge-base "$base" HEAD 2>/dev/null) && [[ $mb != "$head" ]]; then
    from=$mb
  fi

  echo "# このセッションの作業中の変更"
  echo
  echo "- 作業フォルダ: \`$root\`"
  echo "- ブランチ: \`${branch:-（detached HEAD）}\`（HEAD ${head:0:7}）"
  if [[ $from == HEAD ]]; then
    echo "- 比べる基準: HEAD（既定ブランチから進めたコミットがないか、既定ブランチがわからないため、未コミットの変更だけ）"
  else
    echo "- 比べる基準: \`$base\` から分かれたところ（${from:0:7}）"
  fi
  if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    echo "- push していないコミット: $(git rev-list --count "$upstream..HEAD")（追跡先 \`$upstream\`）"
  else
    echo "- push していないコミット: 追跡先なし（まだ push していない）"
  fi
  if [[ -n $branch ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    pr=$(gh pr view --json number,title,url,state --jq '"\(.url)（\(.state)）\(.title)"' 2>/dev/null || true)
    echo "- 今のブランチの PR: ${pr:-なし}"
  fi

  echo
  echo "## コミット（基準から）"
  echo
  if [[ $from == HEAD ]]; then
    echo "なし"
  else
    commits=$(git log --format='- %h %s（%ad）' --date=format:'%m/%d %H:%M' -n 50 "$from..HEAD")
    echo "${commits:-なし}"
  fi

  echo
  echo "## 未コミットの変更"
  echo
  status=$(git status --porcelain)
  if [[ -z $status ]]; then
    echo "なし"
  else
    echo '```'
    head -n 40 <<<"$status"
    count=$(wc -l <<<"$status" | tr -d ' ')
    ((count <= 40)) || echo "...（ほか $((count - 40)) ファイル）"
    echo '```'
    grep -q '^??' <<<"$status" && echo "- \`??\` は未追跡の新しいファイル。差分には入らないので Read で読む"
  fi

  echo
  echo "## 差分"
  echo
  name=$(basename "$root")
  dir="$out_root/session/$name"
  mkdir -p "$dir"
  diff_file="$dir/$(tr '/' '-' <<<"${branch:-detached}")-$(date +%Y%m%d-%H%M%S).diff"
  git diff "$from" >"$diff_file"
  if [[ -s $diff_file ]]; then
    echo "- 保存: ${diff_file}（$(lines "$diff_file") 行）"
    echo "- 規模: $(git diff --shortstat "$from" | sed 's/^ *//')"
  else
    rm -f "$diff_file"
    echo "- 追跡しているファイルの変更はありません"
  fi

  launch_hints "$root"
  exit 0
fi

# --- PR があるとき ------------------------------------------------------------------

if ! gh auth status >/dev/null 2>&1; then
  echo "gh が未ログインです。\`gh auth login\` を実行してください。" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! gh pr view "$number" --repo "$owner/$repo" \
     --json number,title,url,state,isDraft,body,author,baseRefName,headRefName,headRefOid,isCrossRepository,headRepository,headRepositoryOwner,additions,deletions,changedFiles,files,commits,closingIssuesReferences \
     >"$tmp/pr.json" 2>"$tmp/err"; then
  echo "PR $owner/$repo#$number を取得できません: $(head -1 "$tmp/err")" >&2
  exit 1
fi

jq -r '
  def clean: gsub("<!--[\\s\\S]*?-->"; "") | gsub("\\n\\s*\\n(\\s*\\n)+"; "\n\n") | gsub("^\\s+|\\s+$"; "");
  "# PR: \(.title)（\($repo)#\(.number)）",
  "",
  "- URL: \(.url)",
  "- 状態: \(.state)\(if .isDraft then "・Draft" else "" end) / 作成: @\(.author.login // "ghost")",
  "- ブランチ: \(if .isCrossRepository then "\(.headRepositoryOwner.login // "?")/\(.headRepository.name // "?"):" else "" end)\(.headRefName) → \(.baseRefName)（head \(.headRefOid[0:7])）",
  "- 規模: \(.changedFiles) ファイル / +\(.additions) -\(.deletions) / コミット \(.commits | length) 件",
  "",
  "## 本文",
  "",
  "<pr-body>",
  (.body | clean | if . == "" then "（本文なし）" else . end),
  "</pr-body>",
  "",
  "## 変更ファイル（\(.changedFiles) 件\(if .changedFiles > (.files | length) then "、先頭 \(.files | length) 件のみ" else "" end)）",
  "",
  (.files[] | "- \(.path)（+\(.additions) -\(.deletions)）"),
  "",
  "## コミット",
  "",
  (.commits[-30:][] | "- \(.oid[0:7]) \(.messageHeadline)")
' --arg repo "$owner/$repo" "$tmp/pr.json"

head_oid=$(jq -r '.headRefOid' "$tmp/pr.json")
head_ref=$(jq -r '.headRefName' "$tmp/pr.json")
dir="$out_root/$owner/$repo/pr-$number"
mkdir -p "$dir"

# 閉じる Issue はすべて取得して全文を保存し、出力では長い本文だけ省略する
echo
echo "## PR が閉じる Issue"
echo
issues=$(jq -r '.closingIssuesReferences[]?.url' "$tmp/pr.json")
if [[ -z $issues ]]; then
  printf 'なし\n\n'
else
  issues_file="$dir/${head_oid:0:7}-issues.md"
  : >"$issues_file"
  while read -r url; do
    gh issue view "$url" --json title,url,body --jq '
      def clean: gsub("<!--[\\s\\S]*?-->"; "") | gsub("\\n\\s*\\n(\\s*\\n)+"; "\n\n") | gsub("^\\s+|\\s+$"; "");
      "### \(.title)（\(.url)）", "", "<issue-body>", (.body | clean | if . == "" then "（本文なし）" else . end), "</issue-body>", ""' \
      >>"$issues_file" 2>/dev/null || printf -- '- %s（取得できませんでした）\n\n' "$url" >>"$issues_file"
  done <<<"$issues"
  echo "- 全文の保存: ${issues_file}（下で省略した本文はここで読む）"
  echo
  awk '
    /^<issue-body>$/ { inbody = 1; n = 0; print; next }
    /^<\/issue-body>$/ { if (n > 3000) print "…（長いため省略。全文は保存したファイルで読む）"; inbody = 0; print; next }
    inbody { n += length($0) + 1; if (n <= 3000) print; next }
    { print }' "$issues_file"
fi

echo "## 差分"
echo
diff_file="$dir/${head_oid:0:7}.diff"
if gh pr diff "$number" --repo "$owner/$repo" >"$diff_file" 2>"$tmp/err"; then
  echo "- 保存: ${diff_file}（$(lines "$diff_file") 行）"
else
  rm -f "$diff_file"
  echo "- ⚠️ 差分を取得できませんでした: $(head -1 "$tmp/err")"
fi

echo
echo "## ローカル"
echo
# リポジトリ名の . を正規表現の任意の 1 文字として扱わないようにエスケープする
remote_re="github\\.com[:/]${owner//./\\.}/${repo//./\\.}(\\.git)?[[:space:]]"
if remotes=$(git remote -v 2>/dev/null) && grep -qiE "$remote_re" <<<"$remotes"; then
  root=$(git rev-parse --show-toplevel)
  branch=$(git branch --show-current)
  dirty=$(git status --porcelain | awk 'END { print NR }')
  remote=$(grep -iE "$remote_re" <<<"$remotes" | awk 'NR == 1 { print $1 }')
  echo "- 今のフォルダ（\`$root\`、ブランチ \`${branch:-（detached）}\`）はこのリポジトリの clone（リモート名 \`$remote\`）"
  if [[ $(git rev-parse HEAD) == "$head_oid" ]]; then
    echo "- HEAD が PR の head と一致。このフォルダでそのまま起動できる"
    ((dirty == 0)) || echo "- ⚠️ 未コミットの変更が $dirty 件ある（PR には含まれていない）"
  elif [[ $branch == "$head_ref" ]]; then
    echo "- PR のブランチだが HEAD が PR の head と違う（pull していないか、push していないコミットがある）"
  else
    echo "- 今のブランチは PR のブランチではない（このフォルダのブランチは切り替えず、別の worktree に取り出して起動する）"
  fi
  launch_hints "$root"
else
  echo "- 今のフォルダはこのリポジトリの clone ではない（起動の手順は PR のリポジトリの README などから読む）"
fi
