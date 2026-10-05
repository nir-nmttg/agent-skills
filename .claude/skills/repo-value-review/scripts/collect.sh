#!/usr/bin/env bash
# いまいるリポジトリ（手元のコード）を利用者目線でたどるための材料を Markdown で出力する。
# 同じ内容を $REPO_VALUE_REVIEW_DIR（既定: ~/repo-value-reviews）/<owner>/<repo>/<日付>.materials.md にも保存する。
#
# 使い方: collect.sh [<GitHub の URL | owner/repo>]
#   引数を渡すと、いまのフォルダがそのリポジトリの clone かを確かめる（違えば終了する）
#
# 読み取り専用。依存のインストール・ビルド・アプリの起動はしない。
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "git リポジトリの中で実行してください（見直したいリポジトリのフォルダで Claude Code を開く）。" >&2
  exit 1
}
cd "$root"

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

owner="" repo=""
remote=$(git remote get-url origin 2>/dev/null || git remote -v | awk 'NR == 1 { print $2 }')
if [[ $remote =~ github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]]; then
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]%.git}
fi

# リポジトリ名が変わっていても origin は旧名のまま動くので、GitHub 上の正式名にそろえる
canonical() { gh api "repos/$1" --jq .full_name 2>/dev/null || echo "$1"; }
if [[ -n $owner ]] && command -v gh >/dev/null; then
  full=$(canonical "$owner/$repo")
  owner=${full%%/*} repo=${full#*/}
fi

for arg in "$@"; do
  want=""
  if [[ $arg =~ github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]] ||
     [[ $arg =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    want="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  fi
  [[ -n $want ]] || continue
  if [[ $(lower "$want") != $(lower "$owner/$repo") && $(lower "$(canonical "$want")") != $(lower "$owner/$repo") ]]; then
    echo "いまのフォルダ（$root）は $want の clone ではありません${owner:+（$owner/$repo の clone です）}。" >&2
    echo "$want のフォルダで Claude Code を開いてから実行してください。" >&2
    exit 1
  fi
done

if [[ -n $owner ]]; then
  id="$owner/$repo"
else
  id="local/$(basename "$root" | tr -c 'A-Za-z0-9_.\n-' '_')"
fi
today=$(date +%F)
days_ago() { date -v-"$1"d +%F 2>/dev/null || date -d "$1 days ago" +%F; }
out_dir="${REPO_VALUE_REVIEW_DIR:-$HOME/repo-value-reviews}/$id"
mkdir -p "$out_dir"
out="$out_dir/$today.materials.md"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ここから先は 1 項目の失敗で全体を止めない
set +e

gh_ok="" gh_note=""
if [[ -z $owner ]]; then
  gh_note="GitHub のリモート（origin）がない"
elif ! command -v gh >/dev/null; then
  gh_note="gh コマンドがない"
elif ! gh auth status >/dev/null 2>&1; then
  gh_note="gh が未ログイン（\`gh auth login\` が必要）"
else
  gh_ok=1
fi

# ---- GitHub の情報を並列で取っておく ----
if [[ -n $gh_ok ]]; then
  gh api graphql -f owner="$owner" -f name="$repo" -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner description url homepageUrl isArchived isPrivate isFork pushedAt
        defaultBranchRef { name } primaryLanguage { name }
        repositoryTopics(first: 10) { nodes { topic { name } } }
        hasIssuesEnabled hasDiscussionsEnabled
        issues(states: OPEN) { totalCount }
        releases(first: 6, orderBy: { field: CREATED_AT, direction: DESC }) {
          totalCount nodes { tagName name publishedAt isPrerelease isDraft url }
        }
        refs(refPrefix: "refs/tags/", first: 20, orderBy: { field: TAG_COMMIT_DATE, direction: DESC }) {
          totalCount
          nodes { name target { ... on Commit { committedDate } ... on Tag { target { ... on Commit { committedDate } } } } }
        }
        discussions(first: 10, orderBy: { field: UPDATED_AT, direction: DESC }) {
          totalCount nodes { number title url upvoteCount isAnswered createdAt category { name } comments { totalCount } }
        }
      }
    }' >"$tmp/meta.json" 2>/dev/null &

  # 利用者の声。反応・コメントの多いもの、返信のないもの、直近 1 年の一覧、見送られたもの
  q="repo:$id is:issue"
  gh api graphql \
    -f q1="$q is:open sort:reactions-desc" \
    -f q2="$q is:open sort:comments-desc" \
    -f q3="$q is:open comments:0 created:<$(days_ago 14)" \
    -f q4="$q created:>=$(days_ago 365) sort:created-desc" \
    -f q5="$q is:closed reason:\"not planned\" sort:updated-desc" \
    -f query='
    query($q1: String!, $q2: String!, $q3: String!, $q4: String!, $q5: String!) {
      top: search(query: $q1, type: ISSUE, first: 10) { issueCount nodes { ...f } }
      talk: search(query: $q2, type: ISSUE, first: 8) { issueCount nodes { ...f } }
      noreply: search(query: $q3, type: ISSUE, first: 5) { issueCount nodes { ...f } }
      recent: search(query: $q4, type: ISSUE, first: 80) { issueCount nodes { ...f } }
      declined: search(query: $q5, type: ISSUE, first: 8) { issueCount nodes { ...f } }
    }
    fragment f on Issue {
      number title url state createdAt authorAssociation
      reactions { totalCount } comments { totalCount } labels(first: 4) { nodes { name } }
    }' >"$tmp/voice.json" 2>"$tmp/voice.err" &
fi

# ---- ファイル一覧 ----
git -c core.quotePath=false ls-files >"$tmp/files"
VENDOR_RE='(^|/)(node_modules|vendor|third_party|bower_components|dist|build|out|coverage|\.next|\.nuxt|Pods|Carthage|DerivedData|generated|__generated__|public/(assets|packs))/|\.min\.(js|css)$|\.(map|snap)$'
TEST_RE='(^|/)(tests?|specs?|__tests__|__mocks__|fixtures|androidTest|e2e|cypress|playwright|stories|storybook)/|(_test|_spec|\.test|\.spec|\.stories|-test|-spec|Test|Tests|Spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$'
SRC_RE='\.(js|jsx|mjs|cjs|ts|tsx|vue|svelte|astro|rb|erb|haml|slim|py|go|rs|java|kt|swift|dart|php|blade\.php|ex|exs|heex|cs|cshtml|razor|html|sh|bash)$'
I18N_RE='((^|/)(locales?|i18n|lang|langs|translations|l10n)/.*|(^|/)messages/[a-z]{2}([-_][A-Za-z]{2})?)\.(json|ya?ml|po|arb|xliff|strings|properties|toml|js|ts)$|\.(po|arb|xliff|strings)$'
grep -vE "$VENDOR_RE" "$tmp/files" | grep -vE "$TEST_RE" >"$tmp/main"
# 正規表現に合うファイル（生成物・テストを除く）
files() { grep -E "$1" "$tmp/main"; }
filesi() { grep -iE "$1" "$tmp/main"; }
# 利用者が目にするものを探す対象（コードと文言ファイル。マイグレーションは除く）
grep -E "$SRC_RE|$I18N_RE|\.(json|ya?ml)$" "$tmp/main" | grep -vE '(^|/)(db/(migrate|seeds?)|migrations?|deploy|docker|infra|terraform|\.github)/|(^|/)(package(-lock)?|tsconfig[^/]*|composer)\.json$' >"$tmp/ux"
# 行を $1 文字までに切る（cut -c はバイト単位で日本語が化けるため perl で文字単位に切る）
clip() { perl -CSD -ne 'chomp; s/\s+/ /g; $_ = substr($_, 0, '"$1"') . "\x{2026}" if length > '"$1"'; print "$_\n"' 2>/dev/null; }
# 利用者が目にするものを検索して「パス:行: 内容」を出す（$1: 正規表現, $2: 件数, $3: 大文字小文字を区別するなら空文字）
ux_grep() {
  [[ -s $tmp/ux ]] || return 0
  tr '\n' '\0' <"$tmp/ux" | xargs -0 grep -nHIE ${3--i} -- "$1" 2>/dev/null | head -"${2:-15}" | clip 200
}
ux_count() {
  [[ -s $tmp/ux ]] || { echo 0; return; }
  tr '\n' '\0' <"$tmp/ux" | xargs -0 grep -hIicE -- "$1" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'
}
# 一覧を最大 $2 件、超えた分は件数だけ出す
cap() { awk -v n="$1" 'NR <= n { print } END { if (NR > n) print "- …ほか " NR - n " 件" }'; }
inline() { head -"${1:-15}" | tr '\n' ' ' | sed 's/ $//'; }

# ---- 出力 ----
section_overview() {
  local head_sha head_date branch dirty default link_base link_note
  head_sha=$(git rev-parse HEAD 2>/dev/null)
  head_date=$(git log -1 --format=%cs 2>/dev/null)
  branch=$(git branch --show-current)
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  default=$(jq -r '.data.repository.defaultBranchRef.name // empty' "$tmp/meta.json" 2>/dev/null)
  [[ -n $default ]] || default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  echo "$default" >"$tmp/default_branch"

  echo "# 利用者目線で見直す材料: $id"
  echo
  echo "- 調べた日: $today"
  echo "- ローカル: \`$root\`（ブランチ \`${branch:-detached}\`、HEAD \`${head_sha:0:7}\` $head_date、未コミットの変更 $dirty 件）"
  echo "- レポート ID: \`$id\`（publish-report.sh に渡す）"
  if [[ -n $owner ]]; then
    if [[ -n $head_sha ]] && git branch -r --contains "$head_sha" 2>/dev/null | grep -q .; then
      link_base="https://github.com/$id/blob/$head_sha/"
    else
      link_base="https://github.com/$id/blob/${default:-HEAD}/"
      link_note="（HEAD が未 push のため既定ブランチへのリンク。行がずれることがある）"
    fi
    echo "- リンクの基準: $link_base${link_note:-}（ファイルへのリンクは「基準 + パス + #L行」）"
  fi
  if [[ -n $gh_ok && -s $tmp/meta.json ]]; then
    jq -r '.data.repository // empty
      | "- GitHub: \(.url) ・ \(if .isPrivate then "非公開" else "公開" end)\(if .isArchived then " ・ ⚠️ アーカイブ済み" else "" end)\(if .isFork then " ・ フォーク" else "" end) ・ 既定ブランチ `\(.defaultBranchRef.name // "?")` ・ 主な言語 \(.primaryLanguage.name // "?") ・ 最終 push \(.pushedAt[0:10])",
        "- 説明: \(.description // "（なし）")\(if (.repositoryTopics.nodes | length) > 0 then " ・ トピック: " + ([.repositoryTopics.nodes[].topic.name] | join(", ")) else "" end)",
        "- ホームページ: \(.homepageUrl // "" | if . == "" then "（なし）" else . end)"' "$tmp/meta.json"
  else
    echo "- GitHub の情報: 取得せず（${gh_note:-取得に失敗}）"
  fi
  echo "- 追跡ファイル: $(wc -l <"$tmp/files" | tr -d ' ') 件"
  echo
}

section_kind() {
  local f fw found=""
  echo "## 1. 種類の手がかり"
  echo
  for f in $(files '(^|/)package\.json$' | head -8); do
    found=1
    jq -r --arg f "$f" '
      ([(.dependencies // {}), (.devDependencies // {})] | add // {} | keys
        | map(select(test("^(next|nuxt|react|vue|svelte|@sveltejs/kit|astro|@remix-run/react|react-router(-dom)?|@angular/core|solid-js|express|fastify|hono|koa|@nestjs/core|electron|@tauri-apps/api|react-native|expo|commander|yargs|cac|@oclif/core|ink|citty|clipanion|next-intl|next-i18next|react-i18next|i18next|vue-i18n|@tanstack/react-router|@tanstack/react-query|swr|graphql|@apollo/client|tailwindcss|@mui/material|@chakra-ui/react|antd|@radix-ui/react-dialog|shadcn)$")))) as $fw
      | "- \($f): \(.name // "（name なし）")\(if .private then "（private）" else "" end)\(if .description then " — " + .description else "" end)"
        + (if .bin then " ・ bin: " + (if (.bin | type) == "string" then (.name // "?") else (.bin | keys | join(", ")) end) else "" end)
        + (if .exports or .main or .module then " ・ main / exports あり（ライブラリの可能性）" else "" end)
        + (if ($fw | length) > 0 then " ・ " + ($fw | join(", ")) else "" end)
        + (if .scripts.dev or .scripts.start then " ・ 起動: " + ([.scripts.dev, .scripts.start] | map(select(.)) | .[0] | .[0:60]) else "" end)' "$f" 2>/dev/null
  done
  for f in $(files '(^|/)Gemfile$' | head -3); do
    found=1
    echo "- $f: $(grep -oE "^[[:space:]]*gem ['\"](rails|sinatra|hanami|roda|grape|thor|dry-cli|devise|rodauth-rails|omniauth|pundit|action_policy|cancancan|rails-i18n|i18n-tasks|turbo-rails|stimulus-rails|importmap-rails|view_component|graphql|kaminari|pagy|ransack|administrate|activeadmin|avo|noticed|ahoy_matey|good_job|sidekiq|solid_queue)['\"]" "$f" | sed -E "s/.*gem ['\"]//; s/['\"]$//" | sort -u | inline 30)"
  done
  files '\.gemspec$' | head -3 | sed 's/^/- gemspec: /'
  for f in $(files '(^|/)(pyproject\.toml|requirements\.txt|setup\.py)$' | head -3); do
    found=1
    fw=$(grep -oiE '\b(django|flask|fastapi|starlette|streamlit|gradio|click|typer|textual|rich)\b' "$f" | tr '[:upper:]' '[:lower:]' | sort -u | inline 20)
    echo "- $f: ${fw:-（目立つフレームワークなし）}$(grep -qE '^\[project\.scripts\]|entry_points' "$f" && echo ' ・ コマンドの定義あり')"
  done
  for f in $(files '(^|/)go\.mod$' | head -2); do
    found=1
    echo "- $f: $(awk '$1 == "module" { print $2 }' "$f") $(grep -oE 'spf13/cobra|urfave/cli|gin-gonic/gin|labstack/echo|go-chi/chi|gofiber/fiber' "$f" | sort -u | inline)"
  done
  files '(^|/)cmd/[^/]+/' | awk -F/ '{ for (i = 1; i < NF; i++) if ($i == "cmd") { print $(i + 1); break } }' | sort -u | inline 15 | sed '/^$/d; s/^/- cmd\/ 配下のコマンド: /'
  for f in $(files '(^|/)Cargo\.toml$' | head -2); do
    found=1
    echo "- $f: $(grep -oE '^\[\[bin\]\]|^\[lib\]|\b(clap|axum|actix-web|rocket|tauri|leptos|yew)\b' "$f" | sort -u | inline)"
  done
  for f in $(files '(^|/)composer\.json$' | head -2); do
    found=1
    echo "- $f: $(grep -oE '"(laravel/framework|symfony/[a-z-]+|livewire/livewire|inertiajs/inertia-laravel|filament/filament)"' "$f" | tr -d '"' | sort -u | inline)"
  done
  files '(^|/)pubspec\.yaml$' | head -2 | sed 's/^/- Flutter: /'
  files '\.xcodeproj/project\.pbxproj$|(^|/)AndroidManifest\.xml$' | head -4 | sed 's/^/- モバイル: /'
  local api deploy
  api=$(filesi '(^|/)[^/]*(openapi|swagger)[^/]*\.(ya?ml|json)$|\.graphqls$|(^|/)schema\.graphql$' | inline 8)
  [[ -n $api ]] && echo "- API の定義: $api"
  deploy=$(files '(^|/)(Dockerfile|Procfile|vercel\.json|netlify\.toml|fly\.toml|render\.ya?ml|wrangler\.(toml|jsonc?)|app\.ya?ml|firebase\.json|amplify\.ya?ml|serverless\.ya?ml|eas\.json|config/deploy\.yml|compose\.ya?ml|docker-compose\.ya?ml)$' | inline 10)
  [[ -n $deploy ]] && echo "- 動かし方・デプロイの手がかり: $deploy"
  local ports
  ports=$(cat $(files '(^|/)(package\.json|Procfile[^/]*|compose\.ya?ml|docker-compose\.ya?ml|\.env\.(example|sample))$' | head -8) /dev/null 2>/dev/null |
    grep -oE '(localhost|127\.0\.0\.1):[0-9]{4,5}|(-p|--port|PORT=?)[ =]?[0-9]{4,5}|"[0-9]{4,5}:[0-9]{4,5}"' | sort -u | inline 8)
  if [[ -z $ports ]]; then
    ports=$(cat $(files '(^|/)(package\.json|Procfile[^/]*)$' | head -8) /dev/null 2>/dev/null |
      grep -oE '"(dev|start)"[[:space:]]*:[[:space:]]*"[^"]*(next|nuxt|vite|astro|remix|react-scripts|rails|bin/dev)[^"]*"|^web:.*rails' |
      sed -E 's/.*(next|nuxt|react-scripts|rails|bin\/dev).*/localhost:3000（既定）/; s/.*vite.*/localhost:5173（既定）/; s/.*astro.*/localhost:4321（既定）/; s/.*remix.*/localhost:5173（既定）/' | sort -u | inline 3)
    [[ -z $ports ]] && files '^bin/dev$|(^|/)Procfile\.dev$' | grep -q . && files '(^|/)Gemfile$' | grep -q . && ports="localhost:3000（Rails の既定）"
  fi
  [[ -n $ports ]] && echo "- ローカルのポートの手がかり: $ports"
  local execs
  execs=$(git ls-files -s 2>/dev/null | awk '$1 == "100755" { $1 = $2 = $3 = ""; sub(/^ +/, ""); print }' | grep -vE "$VENDOR_RE|$TEST_RE" | grep -vE '^\.(github|husky)/' | inline 15)
  [[ -n $execs ]] && echo "- 実行可能なファイル: $execs"
  [[ -n $found ]] || echo "- 主な定義ファイル（package.json・Gemfile など）: なし"
  echo
}

section_start() {
  echo "## 2. 始める・試す（導入とオンボーディング）"
  echo
  local readme
  readme=$(grep -iE '^readme(\.[a-z]+)?$' "$tmp/files" | head -1)
  if [[ -n $readme ]]; then
    echo "- $readme: $(wc -l <"$readme" | tr -d ' ') 行。見出し（行番号）:"
    # コードブロック内の # コメントは見出しではないので飛ばす
    awk '/^[[:space:]]*```/ { f = !f; next } !f && match($0, /^#+ /) && RLENGTH <= 4 { print "  - " NR " " $0 }' "$readme" | head -40
  else
    echo "- README: なし"
  fi
  local docs examples envs onboard
  docs=$(grep -E '^docs?/' "$tmp/files" | grep -vE "$VENDOR_RE")
  echo "- docs/: $(grep -c . <<<"$docs" | tr -d ' ') 件"
  [[ -n $docs ]] && head -30 <<<"$docs" | sed 's/^/  - /' && (($(wc -l <<<"$docs") > 30)) && echo "  - …ほか $(($(wc -l <<<"$docs") - 30)) 件"
  examples=$(grep -E '^([^/]+/)?(examples?|samples?|demo|playground)/' "$tmp/files" | grep -vE "$VENDOR_RE" | awk -F/ '{ for (i = 1; i <= 2; i++) if ($i ~ /^(examples?|samples?|demo|playground)$/) { o = $1; for (j = 2; j <= i + 1 && j < NF; j++) o = o "/" $j; print o; break } }' | sort -u | inline 15)
  echo "- サンプル・デモ: ${examples:-なし}"
  envs=$(grep -E '(^|/)\.env[^/]*\.(example|sample|template|dist)$|(^|/)example\.env$' "$tmp/files" | inline 5)
  echo "- 環境変数のサンプル: ${envs:-なし}"
  local others
  others=$(grep -iE '^(changelog|history|releases|upgrading|migration|migrating|faq|support|security|contributing)(\.[a-z]+)?$|^docs?/[^/]*(getting[-_]?started|quick[-_]?start|install|tutorial|faq|troubleshoot|migrat|upgrad)[^/]*$' "$tmp/files" | inline 12)
  echo "- CHANGELOG・FAQ・移行ガイドなど: ${others:-なし}"
  echo
  echo "登録・ログイン・初回まわりのファイル（パス名から）:"
  onboard=$(filesi '(sign[-_]?up|sign[-_]?in|log[-_]?in|register|registration|onboard|welcome|invit|tutorial|getting[-_]?started|first[-_]?run|password[-_]?reset|verify|confirm)' | grep -E "$SRC_RE" | grep -viE '(^|/)(db|migrations?)/')
  if [[ -n $onboard ]]; then sed 's/^/- /' <<<"$onboard" | cap 20; else echo "- 見つからない"; fi
  echo
}

# Next.js / SvelteKit / Astro / Nuxt などのファイルベースのルーティングを「/パス ← ファイル」にする
file_routes() {
  {
    files '(^|/)app/(.*/)?page\.(tsx|jsx|ts|js|mdx)$' | awk '{ r = $0; sub(/^(.*\/)?app\//, "", r); sub(/page\.[a-z]+$/, "", r); print r "\t" $0 }'
    files '(^|/)pages/.+\.(tsx|jsx|ts|js|vue|astro|md|mdx)$' | grep -vE '(^|/)pages/api/|/_(app|document)\.' |
      awk '{ r = $0; sub(/^(.*\/)?pages\//, "", r); sub(/\.[a-z]+$/, "", r); sub(/(^|\/)index$/, "", r); print r "\t" $0 }'
    files '(^|/)src/routes/(.*/)?\+page\.svelte$' | awk '{ r = $0; sub(/^(.*\/)?src\/routes\//, "", r); sub(/\+page\.svelte$/, "", r); print r "\t" $0 }'
    files '(^|/)app/routes/[^/]+\.(tsx|jsx|ts|js)$' | awk '{ r = $0; sub(/^(.*\/)?app\/routes\//, "", r); sub(/\.[a-z]+$/, "", r); print r "（Remix 形式）\t" $0 }'
  } | awk -F'\t' '{ r = $1; gsub(/\([^)\/]*\)\/?/, "", r); gsub(/@[^\/]+\/?/, "", r); sub(/\/$/, "", r); print "- /" r " ← " $2 }'
}

section_main() {
  echo "## 3. 主な作業（画面・コマンド・API の一覧）"
  echo
  local routes
  routes=$(file_routes)
  if [[ -n $routes ]]; then
    echo "ファイルベースのルート（$(wc -l <<<"$routes" | tr -d ' ') 件）:"
    cap 60 <<<"$routes"
    echo
  fi
  local f
  for f in $(files '(^|/)config/routes(\.rb|/[^/]+\.rb)$' | head -4); do
    echo "$f（コメント・空行を除く。数字は行番号）:"
    grep -nvE '^[[:space:]]*(#|$)' "$f" | sed -E 's/^([0-9]+):/\1  /; s/^/    /' | cap 80
    echo
  done
  if files '^app/views/' | grep -q .; then
    echo "app/views のディレクトリ（数字は画面テンプレートの数）: $(files '^app/views/[^/]+/' | awk -F/ '{ print $3 }' | sort | uniq -c | sort -rn | awk '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1 }' | clip 900)"
    echo
  fi
  for f in $(files '(^|/)routes/(web|api)\.php$|(^|/)urls\.py$' | head -5); do
    echo "$f:"
    grep -nE 'Route::|path\(|re_path\(' "$f" | clip 150 | sed -E 's/^([0-9]+):[[:space:]]*/\1  /; s/^/    /' | cap 40
    echo
  done
  local rewrites
  rewrites=$( { files '(^|/)(src/)?(middleware|proxy)\.(ts|js)$'; grep -lE 'rewrites|redirects' $(files '(^|/)(next|nuxt|vite|astro)\.config\.[a-z]+$|(^|/)(vercel|netlify)\.(json|toml)$|(^|/)_redirects$') /dev/null 2>/dev/null; } | sort -u | inline 6)
  [[ -n $rewrites ]] && echo "⚠️ URL の書き換え・転送の設定あり（実際の URL がファイルのパスと違うことがある）: $rewrites" && echo
  local found
  found=$(ux_grep "(\b(app|router|server|api|r|route|routes)\.(get|post|put|patch|delete|route|all)\(\s*['\"\`]/)|(\bpath:\s*['\"\`]/)|(<Route[^>]*path=)|(GoRoute\()" 50 | grep -vE "$I18N_RE" | grep -viE 'cookie')
  if [[ -n $found ]]; then
    echo "コード中のルート定義（サーバー・クライアント）:"
    sed 's/^/- /' <<<"$found" | cap 40
    echo
  fi
  found=$(ux_grep "(\.command\(\s*['\"])|(\bUse:\s*\")|(@[a-z_]+\.command\()|(add_parser\(\s*['\"])|(^\s*desc\s+['\"][a-z])|(^\s*(Usage|使い方)[:：])|(['\"](Usage|使い方)[:：])" 30 "")
  if [[ -n $found ]]; then
    echo "コマンド・使い方の定義:"
    sed 's/^/- /' <<<"$found" | cap 25
    echo
  fi
  local nav
  nav=$(filesi '(^|/)[^/]*(nav|menu|sidebar|side-bar|header|tab-?bar|bottom-?tabs?|layout|footer|breadcrumb)[^/]*\.(tsx|jsx|vue|svelte|astro|erb|haml|slim|html|blade\.php|dart|swift|kt)$')
  echo "ナビゲーション・レイアウトらしきファイル:"
  if [[ -n $nav ]]; then sed 's/^/- /' <<<"$nav" | cap 15; else echo "- 見つからない"; fi
  local roles
  roles=$(ux_grep "(enum[[:space:]:(]+role)|(\brole[s]?\s*[:=]\s*[\[{(]?\s*['\":]?(admin|owner|member|staff|manager|viewer|editor|guest))|(\b(is_?admin|admin\?|hasRole|has_role|current_user\.(admin|role))\b)" 12 | grep -vE "$I18N_RE")
  if [[ -n $roles ]]; then
    echo
    echo "権限・ロールの手がかり（利用者像の推定に使う）:"
    sed 's/^/- /' <<<"$roles"
  fi
  echo
}

section_help() {
  echo "## 4. 困ったとき（エラー・ヘルプ・空の状態）"
  echo
  local errors help i18n
  errors=$(filesi '(^|/)(not-found|error|global-error|_error|404|500|422|503|offline|maintenance)\.[a-z.]+$|(^|/)errors?/[^/]+\.[a-z.]+$|error[-_]?(boundary|page|view)' | grep -E "$SRC_RE")
  echo "エラー画面・エラー処理のファイル:"
  if [[ -n $errors ]]; then sed 's/^/- /' <<<"$errors" | cap 15; else echo "- 見つからない"; fi
  help=$( { file_routes; files '(^|/)app/controllers/.+_controller\.rb$|(^|/)app/views/[^/]+/[^/]+$' | sed 's/^/- /'; } |
    grep -iE '(help|faqs?|support|contacts?|inquir(y|ies)|feedbacks?|guides?|manual|troubleshoot|ヘルプ|問い合わせ)' | grep -vE '^- [^ ]*/(_|partials?/)')
  echo "ヘルプ・問い合わせまわりの画面:"
  if [[ -n $help ]]; then cap 12 <<<"$help"; else echo "- 見つからない"; fi
  echo "- 問い合わせ先らしき記述（mailto: など）: $(ux_count '(mailto:|お問い合わせ|contact us|support@)') 件"
  i18n=$(files "$I18N_RE")
  if [[ -n $i18n ]]; then
    echo "- 文言（翻訳）ファイル: $(wc -l <<<"$i18n" | tr -d ' ') 件（$(head -8 <<<"$i18n" | while IFS= read -r f; do printf '%s %s 行, ' "$f" "$(wc -l <"$f" | tr -d ' ')"; done | sed 's/, $//')）"
  else
    echo "- 文言（翻訳）ファイル: なし（文言はコードに直接書かれている可能性）"
  fi
  echo

  local re
  re='(エラーが発生しました|問題が発生しました|予期しない|しばらくしてから|失敗しました|できませんでした|something went wrong|an error (has )?occurred|unexpected error|unknown error|internal server error|\boops\b)'
  echo "原因や対処を言わない可能性があるエラー文言: $(ux_count "$re") 箇所"
  ux_grep "$re" 15 | sed 's/^/- /'
  echo
  re='(まだ.{0,20}(ありません|いません)|がありません|見つかりませんでした|該当する.{0,10}(ありません|見つかりません)|\bno [a-z ]{0,25} (yet|found)\b|no results|nothing (here|to show)|empty[-_ ]?state|EmptyState)'
  echo "空の状態の文言: $(ux_count "$re") 箇所"
  ux_grep "$re" 10 | sed 's/^/- /'
  echo
  re='(confirm\(|\bconfirmation=\{|\bconfirmation:[[:space:]]*\{|data-turbo-confirm|data-confirm|turbo_confirm|本当に|よろしいですか|取り消せません|are you sure|cannot be undone|ConfirmDialog|AlertDialog)'
  echo "取り消せない操作の確認: $(ux_count "$re") 箇所"
  ux_grep "$re" 6 | sed 's/^/- /'
  echo
}

section_keep() {
  echo "## 5. 続ける・更新する（リリースと変更の届け方）"
  echo
  local cl
  cl=$(grep -iE '^(changelog|history|releases|news)(\.[a-z]+)?$|^docs?/changelog(\.[a-z]+)?$' "$tmp/files" | head -1)
  if [[ -n $cl ]]; then
    echo "- $cl: 最新の見出し $(grep -nE '^#{2,3} ' "$cl" | head -3 | sed -E 's/:#+ /: /' | clip 60 | tr '\n' '/' | sed 's#/$##; s#/# / #g')"
  else
    echo "- CHANGELOG: なし"
  fi
  local version
  version=$(head -1 VERSION 2>/dev/null)
  [[ -n $version ]] && echo "- VERSION ファイル: $version"

  # 基準にするのは最新のリリース。なければデプロイ・リリースらしきタグ（production-*, v1.2.3 など）、それもなければ最新のタグ
  local tags="" tag="" tag_date="" label="最新リリース"
  if [[ -n $gh_ok && -s $tmp/meta.json ]]; then
    jq -r '.data.repository // empty
      | "- GitHub のリリース: \(.releases.totalCount) 件\(if .releases.totalCount > 0 then "（直近: " + ([.releases.nodes[] | select(.isDraft | not) | "\(.tagName) \(.publishedAt[0:10] // "?")\(if .isPrerelease then " pre" else "" end)"] | join(" / ")) + "）" else "" end) ・ タグ \(.refs.totalCount) 件"' "$tmp/meta.json"
    tag=$(jq -r '[.data.repository.releases.nodes[] | select((.isDraft | not) and (.isPrerelease | not))][0] // empty | "\(.tagName)\t\(.publishedAt)"' "$tmp/meta.json" 2>/dev/null)
    tags=$(jq -r '.data.repository.refs.nodes[] | "\(.name)\t\(.target.committedDate // .target.target.committedDate // "")"' "$tmp/meta.json" 2>/dev/null)
  else
    echo "- タグ（手元）: $(git tag 2>/dev/null | wc -l | tr -d ' ') 件"
    tags=$(git for-each-ref --sort=-creatordate --count=20 --format='%(refname:short)%09%(creatordate:iso-strict)' refs/tags 2>/dev/null)
  fi
  if [[ -z $tag && -n $tags ]]; then
    echo "- 最近のタグ: $(cut -f1 <<<"$tags" | inline 5)"
    label="最新のタグ"
    tag=$(grep -iE '^[^[:space:]]*(prod|release)|^v?[0-9]+\.[0-9]+' <<<"$tags" | head -1)
    [[ -n $tag ]] || tag=$(head -1 <<<"$tags")
  fi
  tag_date=$(cut -f2 <<<"$tag")
  tag=$(cut -f1 <<<"$tag")
  if [[ -z $tag ]]; then
    echo "- リリース・タグなし（利用者が変更を知る手段は、CHANGELOG・画面のお知らせなどで確かめる）"
    echo
    return
  fi

  local default subjects
  default=$(cat "$tmp/default_branch" 2>/dev/null)
  if [[ -n $gh_ok ]]; then
    subjects=$(gh api "repos/$id/compare/$tag...${default:-HEAD}" --jq '"ahead \(.ahead_by)", (.commits | reverse | .[] | "\(.commit.committer.date[0:10])  \(.commit.message | split("\n")[0])")' 2>/dev/null)
  fi
  if [[ -z $subjects ]]; then
    subjects=$(printf 'ahead %s\n' "$(git rev-list --count "$tag..HEAD" 2>/dev/null)"; git log --no-merges --format='%cs  %s' "$tag..HEAD" 2>/dev/null)
  fi
  local ahead fix feat picked
  ahead=$(head -1 <<<"$subjects" | awk '{ print $2 }')
  subjects=$(sed 1d <<<"$subjects" | grep -vE '^[0-9-]+  Merge (pull request|branch)')
  fix=$(grep -ciE '^[0-9-]+  ((fix|hotfix|bugfix)(\(.+\))?!?:|fix(es|ed)? |.*(修正|直す|不具合))' <<<"$subjects")
  feat=$(grep -ciE '^[0-9-]+  (feat(\(.+\))?!?:|add(s|ed)? |.*(追加|対応|新規))' <<<"$subjects")
  echo "- $label \`$tag\`（${tag_date:0:10}）以降、既定ブランチに ${ahead:-?} コミット（修正らしきもの $fix ・ 機能らしきもの $feat）"
  picked=$(grep -iE '^[0-9-]+  ((fix|hotfix|bugfix|feat)(\(.+\))?!?:|(fix(es|ed)?|add(s|ed)?) |.*(修正|直す|不具合|追加|対応|新規))' <<<"$subjects")
  if [[ -n $picked ]]; then
    echo "  - そのうち修正・機能らしきもの（新しい順）:"
    head -15 <<<"$picked" | clip 140 | sed 's/^/    - /'
  fi
  echo
}

section_voice() {
  echo "## 6. 利用者の声（Issue・Discussions）"
  echo
  if [[ -z $gh_ok ]]; then
    echo "- 取得せず（$gh_note）"
    return
  fi
  if [[ ! -s $tmp/voice.json ]] || ! jq -e '.data' "$tmp/voice.json" >/dev/null 2>&1; then
    echo "- 取得できず（$(head -c 200 "$tmp/voice.err" 2>/dev/null)）"
    return
  fi
  jq -r '.data.repository // empty
    | if .hasIssuesEnabled then "- Open Issue: \(.issues.totalCount) 件" else "- Issue は無効" end,
      if .hasDiscussionsEnabled then "- Discussions: \(.discussions.totalCount) 件" else empty end' "$tmp/meta.json" 2>/dev/null
  echo "- 起票者の「内部」はリポジトリのオーナー・メンバー・コラボレーター（開発側のタスクのことが多い）、「外部」はそれ以外（利用者の声の可能性が高い）"
  echo
  jq -r '
    def who: if (.authorAssociation | test("OWNER|MEMBER|COLLABORATOR")) then "内部" else "外部" end;
    def row: "- [#\(.number)](\(.url)) \(.title)（\(.state | ascii_downcase)・反応 \(.reactions.totalCount)・💬 \(.comments.totalCount)\([.labels.nodes[].name] | if length > 0 then "・" + join(", ") else "" end)・\(who)・\(.createdAt[0:10])）";
    def rows($s; $min): [$s.nodes[] | select(.reactions.totalCount + .comments.totalCount >= $min)];
    def block($title; $s; $min):
      if (rows($s; $min) | length) == 0 then "\($title): なし", ""
      else "\($title)（\($s.issueCount) 件中）:", (rows($s; $min)[] | row), "" end;
    .data
    | ([.recent.nodes[] | who] | group_by(.) | map("\(.[0]) \(length)") | join(" / ")) as $mix
    | block("反応のある open Issue（多い順）"; .top; 1),
      block("コメントのある open Issue（多い順）"; .talk; 1),
      block("返信がないまま 14 日以上たつ open Issue"; .noreply; 0),
      block("見送られた Issue（closed as not planned）"; .declined; 0),
      "直近 1 年に起票された Issue: \(.recent.issueCount) 件\(if $mix != "" then "（起票者 " + $mix + "）" else "" end)。新しい順に最大 80 件（要望・質問・不具合のまとまりを探す材料）:",
      (if (.recent.nodes | length) == 0 then "- なし" else (.recent.nodes[] | row) end)' "$tmp/voice.json"
  echo
  jq -r '.data.repository // empty
    | select(.hasDiscussionsEnabled and .discussions.totalCount > 0)
    | "最近更新された Discussions:",
      (.discussions.nodes[] | "- [#\(.number)](\(.url)) \(.title)（\(.category.name)・👍 \(.upvoteCount)・💬 \(.comments.totalCount)\(if .isAnswered == false then "・未回答" else "" end)）")' "$tmp/meta.json" 2>/dev/null
}

wait
{
  section_overview
  section_kind
  section_start
  section_main
  section_help
  section_keep
  section_voice
} | tee "$out"
echo
echo "（この材料は $out にも保存した）"
