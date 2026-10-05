#!/usr/bin/env bash
# いまいるリポジトリ（手元の clone）を調べ、技術的な健康診断の材料を Markdown で出力する。
# 同じ内容を $REPO_CHECKUP_DIR（既定: ~/repo-checkups）/<owner>/<repo>/<日付>.materials.md にも保存する。
#
# 使い方: collect.sh [<GitHub の URL | owner/repo>]
#   引数を渡すと、いまのフォルダがそのリポジトリの clone かを確かめる（違えば終了する）
#
# 読み取り専用。依存のインストール・ビルド・テストの実行はしない。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "git リポジトリの中で実行してください（診断したいリポジトリのフォルダで Claude Code を開く）。" >&2
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
out_dir="${REPO_CHECKUP_DIR:-$HOME/repo-checkups}/$id"
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
api_get() { # $1: エンドポイント, $2: 保存先の名前
  gh api -X GET "$1" -f per_page=100 >"$tmp/$2.json" 2>"$tmp/$2.err" || echo failed >"$tmp/$2.failed"
}
if [[ -n $gh_ok ]]; then
  gh api graphql -f owner="$owner" -f name="$repo" -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner description url isArchived isPrivate isFork pushedAt
        defaultBranchRef { name } primaryLanguage { name } licenseInfo { spdxId }
        hasVulnerabilityAlertsEnabled
        issues(states: OPEN) { totalCount } pullRequests(states: OPEN) { totalCount }
      }
    }' >"$tmp/meta.json" 2>/dev/null &
  gh pr list -R "$id" --state open --limit 200 \
    --json number,title,author,createdAt,updatedAt,isDraft,url >"$tmp/prs.json" 2>/dev/null &
  gh run list -R "$id" --limit 200 \
    --json workflowName,conclusion,status,createdAt,headBranch,event,url >"$tmp/runs.json" 2>/dev/null &
  api_get "repos/$id/dependabot/alerts?state=open" dependabot &
  api_get "repos/$id/code-scanning/alerts?state=open" codescan &
  api_get "repos/$id/secret-scanning/alerts?state=open" secrets &
fi

# ---- ファイル一覧 ----
git -c core.quotePath=false ls-files >"$tmp/files"
VENDOR_RE='(^|/)(node_modules|vendor|third_party|bower_components|dist|build|out|coverage|\.next|\.nuxt|Pods|Carthage|DerivedData|generated|__generated__|public/(assets|packs))/|\.min\.(js|css)$|\.(map|snap)$|\.pb(\.gw)?\.go$|_pb2(_grpc)?\.py$|\.(g|freezed)\.dart$|(^|/)db/(schema\.rb|structure\.sql)$'
CODE_RE='\.(js|jsx|mjs|cjs|ts|tsx|vue|svelte|astro|rb|rake|py|go|rs|java|kt|kts|scala|swift|m|mm|c|h|cc|cpp|hpp|cs|php|ex|exs|erl|dart|lua|sh|bash|tf|clj|hs|ml|fs|jl|groovy|pl|erb|haml|slim)$'
TEST_RE='(^|/)(tests?|specs?|__tests__|androidTest|e2e|cypress|playwright)/|(_test|_spec|\.test|\.spec|-test|-spec|Test|Tests|Spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$'
grep -iE "$CODE_RE" "$tmp/files" | grep -vE "$VENDOR_RE" >"$tmp/code"
grep -E "$TEST_RE" "$tmp/code" >"$tmp/tests"
: >"$tmp/loc"
if [[ -s $tmp/code ]]; then
  tr '\n' '\0' <"$tmp/code" | xargs -0 wc -l 2>/dev/null |
    awk '{ n = $1; sub(/^[ \t]*[0-9]+[ \t]/, ""); if ($0 != "total") print n "\t" $0 }' >"$tmp/loc"
fi
# 正規表現に合う追跡ファイル
files() { grep -E "$1" "$tmp/files" | grep -vE "$VENDOR_RE"; }
workflows=$(grep -E '^\.github/(workflows/[^/]+|actions/.+/action)\.ya?ml$' "$tmp/files")
wf_list() { [[ -n $workflows ]] && tr '\n' '\0' <<<"$workflows" | xargs -0 "$@"; }

# ---- バージョン指定の検出（場所<TAB>endoflife.date の製品 ID<TAB>指定）----
map_tool() {
  case $1 in
    node | nodejs) echo nodejs ;; golang | go) echo go ;; java) echo eclipse-temurin ;;
    postgres | postgresql) echo postgresql ;;
    ruby | python | php | terraform | elixir | erlang | rust | kotlin | deno | bun | pnpm | redis) echo "$1" ;;
  esac
}
image_product() {
  case $1 in mcr.microsoft.com/dotnet/*) echo dotnet; return ;; esac
  case ${1##*/} in
    node) echo nodejs ;; python | pypy) echo python ;; golang) echo go ;;
    eclipse-temurin | openjdk | amazoncorretto | temurin) echo eclipse-temurin ;;
    postgres | postgresql | postgis) echo postgresql ;; mongo | mongodb) echo mongodb ;;
    alpine) echo alpine-linux ;; httpd) echo apache-http-server ;; kong) echo kong-gateway ;;
    ruby | php | mysql | mariadb | redis | valkey | nginx | ubuntu | debian | elasticsearch | opensearch | \
      rabbitmq | memcached | tomcat | haproxy | traefik | elixir | erlang | rust | bun | deno | keycloak) echo "${1##*/}" ;;
  esac
}
# 標準入力「場所<TAB>イメージ」を製品とタグに分ける。タグに含まれる OS（alpine3.17, bookworm など）も拾う
image_rows() {
  while IFS=$'\t' read -r loc img; do
    img=$(sed -E 's/["'\'']//g; s/\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}/\1/g; s/@.*//' <<<"$img")
    name=$img tag=""
    if [[ ${img##*/} == *:* ]]; then name=${img%:*} tag=${img##*:}; fi
    p=$(image_product "$(lower "$name")")
    [[ -n $p ]] || continue
    printf '%s\t%s\t%s\n' "$loc" "$p" "${tag:-latest（タグなし）}"
    if [[ $tag =~ alpine([0-9]+\.[0-9]+) ]]; then printf '%s\talpine-linux\t%s\n' "$loc" "${BASH_REMATCH[1]}"; fi
    if [[ $tag =~ (bookworm|bullseye|buster|stretch|trixie) ]]; then printf '%s\tdebian\t%s\n' "$loc" "${BASH_REMATCH[1]}"; fi
    if [[ $tag =~ (bionic|focal|jammy|noble) ]]; then printf '%s\tubuntu\t%s\n' "$loc" "${BASH_REMATCH[1]}"; fi
  done
}
# grep -nH の出力「パス:行:内容」を 1 行ずつ「パス:行<TAB>内容」にする
loc_split() { sed -E 's/^([^:]+):([0-9]+):/\1:\2\t/'; }

detect_versions() {
  local f p v
  # ランタイムのバージョンファイル
  files '(^|/)\.(nvmrc|node-version|ruby-version|python-version|java-version)$' | while IFS= read -r f; do
    case $f in *nvmrc | *node-version) p=nodejs ;; *ruby-version) p=ruby ;; *python-version) p=python ;; *) p=eclipse-temurin ;; esac
    v=$(head -1 "$f" | tr -d '[:space:]')
    [[ -n $v ]] && printf '%s:1\t%s\t%s\n' "$f" "$p" "$v"
  done
  files '(^|/)(\.tool-versions)$' | while IFS= read -r f; do
    awk -v f="$f" '$1 !~ /^#/ && NF >= 2 { print f ":" FNR "\t" $1 "\t" $2 }' "$f"
  done | while IFS=$'\t' read -r loc tool v; do
    p=$(map_tool "$tool") && [[ -n $p ]] && printf '%s\t%s\t%s\n' "$loc" "$p" "$v"
  done
  files '(^|/)\.?mise\.toml$' | while IFS= read -r f; do
    awk -v f="$f" '/^\[/ { t = ($0 ~ /^\[tools\]/) } t && /^[a-z-]+[ \t]*=/ {
      k = $1; v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/[]["'\'' ]/, "", v); sub(/,.*/, "", v); print f ":" FNR "\t" k "\t" v }' "$f"
  done | while IFS=$'\t' read -r loc tool v; do
    p=$(map_tool "$tool") && [[ -n $p ]] && printf '%s\t%s\t%s\n' "$loc" "$p" "$v"
  done
  # Go
  files '(^|/)go\.mod$' | while IFS= read -r f; do
    awk -v f="$f" '$1 == "go" { print f ":" FNR "\tgo\t" $2 } $1 == "toolchain" { v = $2; sub(/^go/, "", v); print f ":" FNR "（toolchain）\tgo\t" v }' "$f"
  done
  # Node.js 系（package.json の依存と engines / volta）
  files '(^|/)package\.json$' | head -15 | while IFS= read -r f; do
    grep -nE '^[[:space:]]*"(react|react-native|next|nuxt|vue|@angular/core|svelte|electron|express|jquery|bootstrap|tailwindcss|eslint|vuetify|quasar|node)"[[:space:]]*:[[:space:]]*"[^"]*[0-9][^"]*"' "$f" |
      sed -E 's/^([0-9]+):[[:space:]]*"([^"]+)"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1\t\2\t\3/' |
      while IFS=$'\t' read -r line name v; do
        note=""
        case $name in
          next) p=nextjs ;; @angular/core) p=angular ;; tailwindcss) p=tailwind-css ;;
          node) p=nodejs note="（engines / volta の指定。範囲なら下限）" ;; *) p=$name ;;
        esac
        printf '%s:%s%s\t%s\t%s\n' "$f" "$line" "$note" "$p" "$v"
      done
    grep -nE '"packageManager"[[:space:]]*:[[:space:]]*"pnpm@' "$f" |
      sed -E "s#^([0-9]+):.*pnpm@([0-9.]+).*#$f:\1\tpnpm\t\2#"
  done
  # Ruby
  files '(^|/)Gemfile\.lock$' | while IFS= read -r f; do
    awk -v f="$f" '/^    rails \([0-9]/ { v = $2; gsub(/[()]/, "", v); print f ":" FNR "\trails\t" v }
      /^RUBY VERSION/ { r = 1; next } r && /ruby [0-9]/ { print f ":" FNR "\truby\t" $2; r = 0 }' "$f"
  done
  files '(^|/)Gemfile$' | while IFS= read -r f; do
    grep -nE "^[[:space:]]*ruby[[:space:]]+['\"][0-9]" "$f" | sed -E "s#^([0-9]+):[^'\"]*['\"]([^'\"]+).*#$f:\1\truby\t\2#"
  done
  # Python
  files '(^|/)requirements[^/]*\.txt$' | while IFS= read -r f; do
    grep -niE '^(django|numpy)[[:space:]]*(==|~=|>=)[[:space:]]*[0-9]' "$f" |
      sed -E "s#^([0-9]+):([A-Za-z]+)[[:space:]]*[=~>]+[[:space:]]*([0-9.]+).*#$f:\1\t\2\t\3#" | awk -F'\t' -v OFS='\t' '{ $2 = tolower($2); print }'
  done
  files '(^|/)(poetry|uv)\.lock$' | while IFS= read -r f; do
    awk -v f="$f" '/^name = "(django|numpy)"$/ { n = $3; gsub(/"/, "", n); next }
      n != "" && /^version = / { v = $3; gsub(/"/, "", v); print f ":" FNR "\t" n "\t" v; n = "" }' "$f"
  done
  files '(^|/)(pyproject\.toml|Pipfile|runtime\.txt)$' | while IFS= read -r f; do
    grep -nE '^(requires-python|python|python_version)[[:space:]]*=|^python-[0-9]' "$f" |
      sed -E "s#^([0-9]+):([a-z_-]+).*[\"'=^~>[:space:]-]([0-9]+\.[0-9]+).*#$f:\1（\2。範囲なら下限）\tpython\t\3#" | grep $'\t'
  done
  # PHP
  files '(^|/)composer\.json$' | while IFS= read -r f; do
    grep -nE '^[[:space:]]*"php"[[:space:]]*:' "$f" | sed -E "s#^([0-9]+):.*:[[:space:]]*\"([^\"]*)\".*#$f:\1（範囲なら下限）\tphp\t\2#"
  done
  files '(^|/)composer\.lock$' | while IFS= read -r f; do
    awk -v f="$f" '/"name": "(laravel\/framework|symfony\/http-kernel)"/ { n = ($0 ~ /laravel/) ? "laravel" : "symfony"; next }
      n != "" && /"version":/ { v = $2; gsub(/[",v]/, "", v); print f ":" FNR "\t" n "\t" v; n = "" }' "$f"
  done
  # Java / Kotlin
  files '(^|/)pom\.xml$' | while IFS= read -r f; do
    awk -v f="$f" '/<artifactId>spring-boot-starter-parent<\/artifactId>/ { s = 1 }
      s && /<version>/ { v = $0; gsub(/.*<version>|<\/version>.*/, "", v); print f ":" FNR "\tspring-boot\t" v; s = 0 }
      /<(java\.version|maven\.compiler\.(source|target|release))>/ { v = $0; sub(/^[^>]*>/, "", v); sub(/<.*/, "", v); print f ":" FNR "\teclipse-temurin\t" v }' "$f"
  done
  files '(^|/)(build\.gradle(\.kts)?|libs\.versions\.toml)$' | while IFS= read -r f; do
    grep -nE "org\.springframework\.boot['\"]?\)?[[:space:]]+version[[:space:]]+['\"][0-9]|^(spring-?[bB]oot|springBoot)[[:space:]]*=[[:space:]]*\"[0-9]" "$f" |
      sed -E "s#^([0-9]+):.*['\"]([0-9][0-9.]*)['\"].*#$f:\1\tspring-boot\t\2#"
    grep -nE "kotlin\(['\"]jvm['\"]\)[[:space:]]+version|org\.jetbrains\.kotlin\.[a-z]+['\"]\)?[[:space:]]+version|kotlin_version[[:space:]]*=|^kotlin[[:space:]]*=[[:space:]]*\"[0-9]" "$f" |
      sed -E "s#^([0-9]+):.*['\"]([0-9][0-9.]*)['\"].*#$f:\1\tkotlin\t\2#"
    grep -nE "JavaVersion\.VERSION_[0-9_]+|JavaLanguageVersion\.of\([0-9]+\)|jvmTarget[[:space:]]*=[[:space:]]*['\"]?[0-9]" "$f" |
      sed -E "s#^([0-9]+):.*(VERSION_(1_)?|of\(|jvmTarget[^0-9]*)([0-9]+).*#$f:\1\teclipse-temurin\t\4#"
  done
  # .NET
  files '\.(cs|fs|vb)proj$|(^|/)Directory\.Build\.props$' | while IFS= read -r f; do
    grep -nE '<TargetFrameworks?>' "$f" | sed -E 's/^([0-9]+):.*<TargetFrameworks?>([^<]*)<.*/\1 \2/' | while read -r line fws; do
      for fw in ${fws//;/ }; do [[ $fw =~ ^net(coreapp)?[0-9] ]] && printf '%s:%s\tdotnet\t%s\n' "$f" "$line" "$fw"; done
    done
  done
  files '(^|/)global\.json$' | while IFS= read -r f; do
    grep -nE '"version"[[:space:]]*:' "$f" | head -1 | sed -E "s#^([0-9]+):.*\"([0-9][^\"]*)\".*#$f:\1\tdotnet\t\2#"
  done
  # コンテナイメージ（Dockerfile の FROM と compose の image）
  files '(^|/)(Dockerfile|Containerfile)[^/]*$|\.dockerfile$' | while IFS= read -r f; do
    awk -v f="$f" '
      function repl(s, from, to,   i) { while ((i = index(s, from)) > 0) s = substr(s, 1, i - 1) to substr(s, i + length(from)); return s }
      toupper($1) == "ARG" && $2 ~ /=/ { k = $2; sub(/=.*/, "", k); v = $2; sub(/^[^=]*=/, "", v); gsub(/["'\'']/, "", v); arg[k] = v }
      toupper($1) == "FROM" { img = ($2 ~ /^--/) ? $3 : $2; for (k in arg) { img = repl(img, "${" k "}", arg[k]); img = repl(img, "$" k, arg[k]) }
        print f ":" FNR "\t" img }' "$f"
  done | image_rows
  { files '(^|/)(docker-)?compose[^/]*\.ya?ml$'; grep -E '^\.github/workflows/' <<<"$workflows"; } | while IFS= read -r f; do
    [[ -n $f ]] && grep -nHE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*[^[:space:]]' "$f" | loc_split | sed -E 's/\t[[:space:]]*-?[[:space:]]*image:[[:space:]]*/\t/'
  done | image_rows
  # GitHub Actions のランタイム指定とランナー
  if [[ -n $workflows ]]; then
    wf_list grep -nHE '^[[:space:]]*-?[[:space:]]*(node|python|ruby|go|java|php|dotnet)-version:' | loc_split |
      while IFS=$'\t' read -r loc content; do
        tool=$(sed -E 's/^[[:space:]]*-?[[:space:]]*([a-z]+)-version:.*/\1/' <<<"$content")
        p=$(map_tool "$tool"); [[ $tool == dotnet ]] && p=dotnet
        [[ -n $p ]] || continue
        for v in $(sed -E 's/^[^:]*:[[:space:]]*//; s/#.*//; s/[]["'\'',]/ /g' <<<"$content"); do
          [[ $v =~ ^[0-9]+(\.[0-9x]+)*$ ]] && printf '%s\t%s\t%s\n' "$loc" "$p" "$v"
        done
      done
    wf_list grep -nHoE '(ubuntu|macos|windows)-[0-9][0-9.]*(-[a-z0-9]+)*' | loc_split | awk -F'\t' -v OFS='\t' '{ print $1, "github-actions-runner-images", $2 }'
  fi
  # AWS Lambda のランタイム（serverless / SAM / Terraform / CDK）
  git grep -nIE "[Rr]untime[\"']?[[:space:]]*[:=][[:space:]]*[\"']?(nodejs|python|ruby|java|dotnet|go1|provided)[0-9a-z.]*" -- '*.yml' '*.yaml' '*.json' '*.tf' '*.toml' 2>/dev/null |
    grep -vE "$VENDOR_RE" | loc_split | while IFS=$'\t' read -r loc content; do
      v=$(grep -oE "(nodejs|python|ruby|java|dotnet|go1|provided)[0-9a-z.]*" <<<"${content#*untime}" | head -1)
      [[ -n $v ]] && printf '%s\taws-lambda\t%s\n' "$loc" "$v"
    done
  git grep -nIE 'Runtime\.(NODEJS|PYTHON|RUBY|JAVA|DOTNET)_[0-9A-Z_]+' -- '*.ts' '*.js' '*.py' '*.java' '*.go' 2>/dev/null |
    grep -vE "$VENDOR_RE" | loc_split | while IFS=$'\t' read -r loc content; do
      v=$(grep -oE 'Runtime\.(NODEJS|PYTHON|RUBY|JAVA|DOTNET)_[0-9A-Z_]+' <<<"$content" | head -1 | sed -E 's/^Runtime\.//; s/_/ /' | tr '[:upper:]' '[:lower:]' | tr -d ' ' | tr '_' '.')
      printf '%s\taws-lambda\t%s\n' "$loc" "$v"
    done
  # Terraform
  git grep -nIE 'required_version[[:space:]]*=' -- '*.tf' 2>/dev/null | loc_split | while IFS=$'\t' read -r loc content; do
    v=$(grep -oE '[0-9]+\.[0-9]+' <<<"$content" | head -1)
    [[ -n $v ]] && printf '%s（範囲なら下限）\tterraform\t%s\n' "$loc" "$v"
  done
}

# サポート期限の判定対象にならないバージョン情報（モバイルの SDK 指定など）
other_versions() {
  files '(^|/)build\.gradle(\.kts)?$' | while IFS= read -r f; do
    grep -nHE '(compileSdk|targetSdk|minSdk)(Version)?[[:space:]]*(=|[[:space:]])[[:space:]]*[0-9]+' "$f"
  done
  files '(^|/)Podfile$' | while IFS= read -r f; do grep -nHE "^[[:space:]]*platform[[:space:]]+:ios" "$f"; done
  files '\.pbxproj$' | head -3 | while IFS= read -r f; do
    grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+' "$f" | sort | uniq -c | awk -v f="$f" '{ print f ": " $2 " " $4 "（" $1 " 箇所）" }'
  done
  files '(^|/)pubspec\.yaml$' | while IFS= read -r f; do grep -nHE '^[[:space:]]+(sdk|flutter):[[:space:]]*["'\''^>=0-9]' "$f"; done
  files '(^|/)Package\.swift$' | while IFS= read -r f; do grep -nHE 'swift-tools-version' "$f"; done
  files '(^|/)\.xcode-version$' | while IFS= read -r f; do printf '%s:1: Xcode %s\n' "$f" "$(head -1 "$f")"; done
}

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

  echo "# 健康診断の材料: $id"
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
      | "- GitHub: \(.url) ・ \(if .isPrivate then "非公開" else "公開" end)\(if .isArchived then " ・ ⚠️ アーカイブ済み" else "" end)\(if .isFork then " ・ フォーク" else "" end) ・ 既定ブランチ `\(.defaultBranchRef.name // "?")` ・ 最終 push \(.pushedAt[0:10]) ・ Open Issue \(.issues.totalCount) / PR \(.pullRequests.totalCount) ・ ライセンス \(.licenseInfo.spdxId // "なし") ・ Dependabot アラート \(if .hasVulnerabilityAlertsEnabled then "有効" else "無効" end)",
        "- 説明: \(.description // "（なし）")"' "$tmp/meta.json"
  else
    echo "- GitHub の情報: 取得せず（${gh_note:-取得に失敗}）"
  fi
  [[ $(git rev-parse --is-shallow-repository 2>/dev/null) == true ]] && echo "- ⚠️ 浅い clone のため、履歴を使う項目（変更の多いファイル・体制）は一部の期間だけ"
  local total code tests lines
  total=$(wc -l <"$tmp/files" | tr -d ' ')
  code=$(wc -l <"$tmp/code" | tr -d ' ')
  tests=$(wc -l <"$tmp/tests" | tr -d ' ')
  lines=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' "$tmp/loc")
  echo "- 規模: 追跡ファイル $total（コード $code、うちテスト $tests）・ コード $lines 行"
  echo "- 言語別の行数: $(awk -F'\t' '{ n = split($2, a, "."); e = (n > 1) ? tolower(a[n]) : "?"; s[e] += $1 } END { for (e in s) print s[e] "\t" e }' "$tmp/loc" |
    sort -rn | head -8 | awk -F'\t' '{ printf "%s.%s %d", (NR > 1 ? " / " : ""), $2, $1 }')"
  echo
}

section_versions() {
  echo "## 1. サポート期限（endoflife.date で判定）"
  echo
  detect_versions >"$tmp/versions.tsv" 2>/dev/null
  bash "$here/eol.sh" <"$tmp/versions.tsv"
  local others
  others=$(other_versions 2>/dev/null | head -20)
  if [[ -n $others ]]; then
    echo
    echo "その他のバージョン指定（判定対象外）:"
    sed 's/^/- /' <<<"$others"
  fi
  echo
}

section_security() {
  echo "## 2. セキュリティ"
  echo
  if [[ -z $gh_ok ]]; then
    echo "- GitHub のアラート: 取得せず（$gh_note）"
  else
    if [[ -e $tmp/dependabot.failed ]]; then
      echo "- Dependabot アラート: 取得できず（$(head -1 "$tmp/dependabot.err")）"
    else
      jq -r '
        def rank: {"critical": 0, "high": 1, "medium": 2, "low": 3}[.] // 4;
        "- Dependabot アラート（open）: \(length)\(if length >= 100 then " 件以上" else " 件" end)\(if length > 0 then "（" + (group_by(.security_advisory.severity) | sort_by(.[0].security_advisory.severity | rank) | map("\(.[0].security_advisory.severity) \(length)") | join(" / ")) + "）" else "" end)",
        (sort_by((.security_advisory.severity | rank), .created_at) | .[:12][]
          | "  - [\(.security_advisory.severity)] \(.dependency.package.name)（\(.dependency.package.ecosystem)）: \(.security_advisory.summary) ・ \(.dependency.manifest_path) ・ 修正版 \(.security_vulnerability.first_patched_version.identifier // "なし") ・ \(.created_at[0:10]) から")' \
        "$tmp/dependabot.json"
    fi
    if [[ -e $tmp/codescan.failed ]]; then
      echo "- Code scanning: 取得できず（$(head -1 "$tmp/codescan.err")）"
    else
      jq -r '
        "- Code scanning アラート（open）: \(length) 件",
        (.[:8][] | "  - [\(.rule.security_severity_level // .rule.severity)] \(.rule.description) ・ \(.most_recent_instance.location.path):\(.most_recent_instance.location.start_line)")' \
        "$tmp/codescan.json"
    fi
    if [[ -e $tmp/secrets.failed ]]; then
      echo "- Secret scanning: 取得できず（$(head -1 "$tmp/secrets.err")）"
    else
      # 秘密の値（.secret）は出さない
      jq -r '"- Secret scanning アラート（open）: \(length) 件\(if length > 0 then "（" + (group_by(.secret_type_display_name) | map("\(.[0].secret_type_display_name) \(length)") | join(" / ")) + "）" else "" end)"' \
        "$tmp/secrets.json"
    fi
  fi

  local sensitive
  sensitive=$(files '(^|/)\.env(\.[A-Za-z0-9_-]+)?$|\.(pem|key|p12|pfx|jks|keystore|mobileprovision|p8|ppk|kdbx)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)(credentials|secrets?|service[-_]?account[^/]*)\.(json|ya?ml)$|(^|/)\.(npmrc|pypirc|netrc|htpasswd)$' |
    grep -vE '\.(example|sample|template|dist|defaults?)$|(^|/)\.env\.(example|sample|template|dist)$' | head -20)
  if [[ -n $sensitive ]]; then
    echo "- git に入っている機密になりがちなファイル:"
    sed 's/^/  - /' <<<"$sensitive"
  else
    echo "- git に入っている機密になりがちなファイル: なし"
  fi

  # 秘密情報らしき文字列。値は出さず「場所（種類）」だけ出す
  echo "- 秘密情報らしき文字列（値は伏せて場所だけ）:"
  local found=""
  while IFS='|' read -r label pattern; do
    hits=$(git grep -nIE "$pattern" 2>/dev/null | grep -vE "$VENDOR_RE" | grep -vE '(^|/)[^/:]*(\.lock|-lock\.json|lock\.yaml):' |
      grep -viE 'localhost|127\.0\.0\.1|example|dummy|\$\{|<[a-z_-]+>' | cut -d: -f1,2 | head -10)
    if [[ -n $hits ]]; then
      found=1
      echo "  - $label: $(tr '\n' ' ' <<<"$hits")"
    fi
  done <<'PATTERNS'
AWS アクセスキー|AKIA[0-9A-Z]{16}
秘密鍵|-----BEGIN [A-Z ]*PRIVATE KEY-----
GitHub トークン|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}
Slack トークン / Webhook|xox[abposr]-[A-Za-z0-9-]{10,}|hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+
Stripe 本番キー|(sk|rk)_live_[A-Za-z0-9]{16,}
Google API キー|AIza[0-9A-Za-z_-]{35}
OpenAI / Anthropic キー|sk-(proj|ant)-[A-Za-z0-9_-]{20,}
パスワード入りの接続文字列|(postgres|postgresql|mysql|mongodb(\+srv)?|redis|amqp)://[^:/@[:space:]]+:[^@/[:space:]$]{3,}@
PATTERNS
  [[ -n $found ]] || echo "  - なし"
  echo
}

section_ci() {
  local default
  default=$(cat "$tmp/default_branch" 2>/dev/null)
  echo "## 3. CI/CD"
  echo
  echo "- GitHub Actions のワークフロー: $(grep -c '^\.github/workflows/' <<<"$workflows" | tr -d ' ') 件$(grep '^\.github/workflows/' <<<"$workflows" | sed 's#^\.github/workflows/##' | head -15 | tr '\n' ',' | sed 's/,$//; s/^/（/; s/$/）/; s/,/, /g; s/^（）$//')"
  local others
  others=$(files '(^|/)(\.circleci/config\.ya?ml|\.gitlab-ci\.ya?ml|Jenkinsfile|\.travis\.ya?ml|bitrise\.ya?ml|codemagic\.ya?ml|azure-pipelines\.ya?ml|buildspec\.ya?ml|cloudbuild\.ya?ml|appveyor\.ya?ml|\.buildkite/[^/]+|Fastfile|vercel\.json|netlify\.toml|fly\.toml|render\.ya?ml|Procfile|serverless\.ya?ml|template\.ya?ml|samconfig\.toml|cdk\.json|app\.ya?ml|Capfile|config/deploy\.yml|\.kamal/[^/]+|firebase\.json|amplify\.ya?ml|eas\.json)$' | head -15 | tr '\n' ' ')
  echo "- ほかの CI・デプロイ関連ファイル: ${others:-なし}"

  if [[ -n $gh_ok && -s $tmp/runs.json ]]; then
    echo
    echo "既定ブランチ（\`$default\`）での直近の実行（最大 200 件中）:"
    echo
    jq -r --arg b "$default" '
      [.[] | select(.headBranch == $b)] as $runs
      | if ($runs | length) == 0 then "- 既定ブランチでの実行なし（直近 200 件中）" else
        "| ワークフロー | 最新 | 成功 / 失敗 | 連続失敗 | 最後の成功 | 最終実行 |",
        "| --- | --- | --- | --- | --- | --- |",
        ($runs | group_by(.workflowName) | map(sort_by(.createdAt) | reverse) | sort_by(.[0].createdAt) | reverse | .[]
          | [.[] | select(.conclusion == "success" or .conclusion == "failure")] as $done
          | "| \(.[0].workflowName) | [\(.[0].conclusion // .[0].status)](\(.[0].url)) | \($done | map(select(.conclusion == "success")) | length) / \($done | map(select(.conclusion == "failure")) | length) | \(reduce $done[] as $r ({n: 0, stop: false}; if .stop then . elif $r.conclusion == "failure" then .n += 1 else .stop = true end) | .n) | \(($done | map(select(.conclusion == "success")) | .[0].createdAt // "なし")[0:10]) | \(.[0].createdAt[0:10]) |")
      end' "$tmp/runs.json"
  fi

  if [[ -n $workflows ]]; then
    # uses: を集計し、使っている Action の最新リリースを並列で調べる
    wf_list grep -nHE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^.[:space:]]' | loc_split |
      sed -E 's/\t[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/\t/; s/["'\'']//g' |
      awk -F'\t' -v OFS='\t' '$2 !~ /^docker:/ { c = $2; sub(/[[:space:]]*#[[:space:]]*/, "\t", c); split(c, a, "\t"); print $1, a[1], a[2] }' >"$tmp/uses.tsv"
    if [[ -s $tmp/uses.tsv ]]; then
      if [[ -n $gh_ok ]]; then
        mkdir -p "$tmp/latest"
        local a
        for a in $(cut -f2 "$tmp/uses.tsv" | sed -E 's/@.*//' | awk -F/ 'NF >= 2 { print $1 "/" $2 }' | sort -u | head -25); do
          { gh api "repos/$a/releases/latest" --jq .tag_name 2>/dev/null || gh api "repos/$a/tags?per_page=1" --jq '.[0].name' 2>/dev/null; } \
            >"$tmp/latest/${a//\//__}" &
        done
        wait
      fi
      echo
      echo "使っている Action（\`uses:\`）:"
      echo
      echo "| Action | 使用中 | 最新リリース | 箇所 | 最初の場所 |"
      echo "| --- | --- | --- | --- | --- |"
      awk -F'\t' '{ k = $2; n[k]++; if (!(k in first)) { first[k] = $1; note[k] = $3 } } END { for (k in n) print k "\t" n[k] "\t" first[k] "\t" note[k] }' "$tmp/uses.tsv" |
        sort | while IFS=$'\t' read -r use count first note; do
          action=${use%@*} ref=${use##*@}
          [[ $use == *@* ]] || ref="（指定なし）"
          a=$(awk -F/ '{ print $1 "/" $2 }' <<<"$action")
          latest=$(cat "$tmp/latest/${a//\//__}" 2>/dev/null | head -1)
          [[ $ref =~ ^[0-9a-f]{40}$ ]] && ref="SHA 固定${note:+（$note）}"
          echo "| $action | $ref | ${latest:-?} | $count | $first |"
        done
    fi

    echo
    echo "ワークフロー内のテスト・lint・ビルドらしき行:"
    local lines
    lines=$(wf_list grep -nHiE '(rspec|jest|vitest|pytest|go test|cargo (test|clippy)|phpunit|rails test|(npm|yarn|pnpm|bun)( run)? (test|lint|build|typecheck|type-check|check)|eslint|rubocop|brakeman|bundle(r)?[ -]audit|tsc( |$)|mypy|ruff|flake8|swiftlint|ktlint|detekt|gradlew[^#]*(test|check|lint)|xcodebuild[^#]*test|fastlane|playwright|cypress|prettier|biome|make (test|lint|check))' |
      loc_split | sed -E 's/\t[[:space:]]*(-[[:space:]]*)?/\t/' | grep -vE $'\t''(#|[A-Za-z0-9_-]+:([[:space:]]|$))' |
      sed -E 's/\t/: /' | cut -c1-160 | head -25)
    # 上で落とした run: の行を戻す
    lines=$(printf '%s\n' "$lines"; wf_list grep -nHiE '^[[:space:]]*-?[[:space:]]*run:.*(rspec|jest|vitest|pytest|go test|cargo |phpunit|rails test|test|lint|build|check|eslint|rubocop|brakeman|audit|tsc|mypy|ruff|flake8|swiftlint|ktlint|detekt|gradlew|xcodebuild|fastlane|playwright|cypress|prettier|biome)' |
      loc_split | sed -E 's/\t[[:space:]]*-?[[:space:]]*/: /' | cut -c1-160)
    lines=$(grep -v '^$' <<<"$lines" | sort -t: -k1,1 -k2,2n -u | head -25)
    if [[ -n $lines ]]; then sed 's/^/- /' <<<"$lines"; else echo "- 見つからない"; fi

    local deprecated
    deprecated=$(wf_list grep -nHE '::(set-output|save-state|set-env|add-path)' | cut -d: -f1,2 | head -10 | tr '\n' ' ')
    [[ -n $deprecated ]] && echo "- 廃止されたワークフローコマンド（::set-output など）: $deprecated"
  fi
  echo
}

section_deps() {
  echo "## 4. 依存の更新"
  echo
  local dep
  dep=$(files '^\.github/dependabot\.ya?ml$' | head -1)
  if [[ -n $dep ]]; then
    echo "- Dependabot 設定: $dep（$(grep -E 'package-ecosystem' "$dep" | sed -E 's/.*:[[:space:]]*//; s/["'\'']//g' | sort | uniq -c | awk '{ printf "%s%s×%s", (NR > 1 ? ", " : ""), $2, $1 }')）"
  else
    echo "- Dependabot 設定: なし"
  fi
  local renovate
  renovate=$(files '(^|/)(renovate\.json5?|\.renovaterc(\.json5?)?|\.github/renovate\.json5?)$' | tr '\n' ' ')
  echo "- Renovate 設定: ${renovate:-なし}"
  local manifests
  manifests=$(files '(^|/)(package\.json|Gemfile|pyproject\.toml|requirements[^/]*\.txt|Pipfile|go\.mod|Cargo\.toml|composer\.json|pom\.xml|build\.gradle(\.kts)?|Package\.swift|Podfile|pubspec\.yaml|mix\.exs|[^/]+\.csproj)$' | head -20 | tr '\n' ' ')
  local locks
  locks=$(grep -E '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|Gemfile\.lock|poetry\.lock|uv\.lock|Pipfile\.lock|go\.sum|Cargo\.lock|composer\.lock|Podfile\.lock|Package\.resolved|pubspec\.lock|mix\.lock|gradle\.lockfile|packages\.lock\.json)$' "$tmp/files" | head -20 | tr '\n' ' ')
  echo "- 依存の定義: ${manifests:-なし}"
  echo "- lockfile: ${locks:-なし}"
  if [[ -n $gh_ok && -s $tmp/prs.json ]]; then
    jq -r '
      def bot: .author.is_bot or (.author.login | test("dependabot|renovate"; "i"));
      ([.[] | select(bot)] | sort_by(.createdAt)) as $b
      | ([.[] | select(bot | not)] | sort_by(.updatedAt)) as $h
      | (now - 30 * 86400 | todate) as $stale
      | "- 依存更新の PR（bot、open）: \($b | length) 件\(if ($b | length) > 0 then "（最古 \($b[0].createdAt[0:10])）" else "" end)",
        ($b[:5][] | "  - #\(.number) \(.title)（\(.createdAt[0:10])）"),
        "- 人の PR（open）: \($h | length) 件（うち 30 日以上更新なし \([$h[] | select(.updatedAt < $stale)] | length) 件）",
        ($h[:3][] | select(.updatedAt < $stale) | "  - #\(.number) \(.title)（@\(.author.login)、最終更新 \(.updatedAt[0:10])\(if .isDraft then "、Draft" else "" end)）")' \
      "$tmp/prs.json"
  fi
  echo
}

section_quality() {
  echo "## 5. テスト・品質"
  echo
  local code tests
  code=$(wc -l <"$tmp/code" | tr -d ' ')
  tests=$(wc -l <"$tmp/tests" | tr -d ' ')
  echo "- テストファイル: $tests 件 / コードファイル $code 件"
  if [[ -s $tmp/tests ]]; then
    echo "- テストの置き場所（上位）: $(awk -F/ '{ print (NF > 2 ? $1 "/" $2 : $1) }' "$tmp/tests" | sort | uniq -c | sort -rn | head -6 | awk '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1 }')"
  fi
  local tcfg lint hooks
  tcfg=$(files '(^|/)((jest|vitest|playwright|cypress|karma)\.config\.[a-z]+|pytest\.ini|tox\.ini|\.rspec|phpunit\.xml(\.dist)?|\.mocharc\.[a-z]+|codecov\.ya?ml|\.simplecov|spec/(spec|rails)_helper\.rb|test/test_helper\.rb|conftest\.py)$' | head -12 | tr '\n' ' ')
  lint=$(files '(^|/)(\.eslintrc(\.[a-z]+)?|eslint\.config\.[a-z]+|\.prettierrc(\.[a-z]+)?|prettier\.config\.[a-z]+|biome\.jsonc?|\.rubocop\.yml|\.golangci\.ya?ml|ruff\.toml|\.flake8|mypy\.ini|\.swiftlint\.yml|\.editorconfig|\.stylelintrc(\.[a-z]+)?|detekt\.yml|\.php-cs-fixer(\.dist)?\.php|phpstan\.neon(\.dist)?|\.erb[-_]lint\.yml|\.haml-lint\.yml|Steepfile|\.hadolint\.ya?ml|rustfmt\.toml|clippy\.toml|\.clang-format|\.markdownlint[^/]*)$' | head -15 | tr '\n' ' ')
  hooks=$(grep -E '^(\.husky/[^/]+|\.pre-commit-config\.yaml|\.?lefthook\.ya?ml|\.overcommit\.yml|\.lintstagedrc[^/]*)$' "$tmp/files" | head -5 | tr '\n' ' ')
  echo "- テストの設定: ${tcfg:-なし}"
  echo "- lint・フォーマット・型の設定: ${lint:-なし}"
  echo "- コミット前フック: ${hooks:-なし}"
  local f
  for f in $(files '(^|/)tsconfig[^/]*\.json$' | head -4); do
    echo "- $f: strict $(grep -qE '"strict"[[:space:]]*:[[:space:]]*true' "$f" && echo "true" || echo "指定なし（extends 先にある可能性）")"
  done
  for f in $(files '(^|/)Gemfile$' | head -2); do
    local gems
    gems=$(grep -oE "gem ['\"](rubocop[a-z_-]*|standard|rspec-rails|minitest|brakeman|bundler-audit|erb_lint|simplecov|sorbet|steep|rails_best_practices|bullet)['\"]" "$f" | sed -E "s/gem ['\"]//; s/['\"]$//" | sort -u | tr '\n' ' ')
    echo "- $f の品質系 gem: ${gems:-なし}"
  done
  for f in $(files '(^|/)pyproject\.toml$' | head -2); do
    echo "- $f の [tool.*]: $(grep -oE '^\[tool\.[a-z_-]+' "$f" | sed 's/^\[tool\.//' | sort -u | tr '\n' ' ')"
  done
  if [[ -f package.json ]]; then
    echo "- package.json の品質系ツール: $(jq -r '[(.dependencies // {}), (.devDependencies // {})] | add // {} | keys[] | select(test("^(eslint|prettier|@biomejs/biome|typescript|jest|vitest|@playwright/test|cypress|husky|lint-staged|stylelint|@testing-library/.+)$"))' package.json 2>/dev/null | tr '\n' ' ')"
    echo "- package.json の scripts:"
    jq -r '.scripts // {} | to_entries[:25][] | "  - \(.key): \(.value | .[0:100])"' package.json 2>/dev/null
  fi
  echo
}

section_code() {
  echo "## 6. コードの健全性"
  echo
  # マイグレーション・seed は一度きりのコードなので、大きさや変更回数の指標から外す
  grep -vE '(^|/)db/(migrate|seeds?)/|(^|/)migrations?/' "$tmp/loc" >"$tmp/loc_main"
  echo "大きいファイル（行数。テスト・生成物・マイグレーションを除く）:"
  awk -F'\t' 'NR == FNR { t[$0] = 1; next } !($2 in t)' "$tmp/tests" "$tmp/loc_main" | sort -t$'\t' -k1,1 -rn | head -10 | awk -F'\t' '{ printf "- %d 行 %s\n", $1, $2 }'
  echo "- 大きいテストファイル: $(awk -F'\t' 'NR == FNR { t[$0] = 1; next } ($2 in t)' "$tmp/tests" "$tmp/loc_main" | sort -t$'\t' -k1,1 -rn | head -3 | awk -F'\t' '{ printf "%s%s (%d 行)", (NR > 1 ? ", " : ""), $2, $1 }')"
  echo
  echo "直近 12 か月で変更の多いファイル（変更回数 / 現在の行数。テストを除く）:"
  git log --since="12 months ago" --no-merges --format= --name-only HEAD 2>/dev/null | grep -v '^$' | sort | uniq -c | sort -rn |
    awk -v tests="$tmp/tests" 'BEGIN { while ((getline t < tests) > 0) skip[t] = 1 }
      NR == FNR { split($0, a, "\t"); loc[a[2]] = a[1]; next }
      { c = $1; sub(/^[ \t]*[0-9]+[ \t]/, ""); if (($0 in loc) && !($0 in skip) && n < 12) { n++; printf "- %d 回 / %d 行 %s\n", c, loc[$0], $0 } }' "$tmp/loc_main" -
  echo
  local todo
  git grep -nIwE '(TODO|FIXME|HACK|XXX)' 2>/dev/null | grep -iE "^[^:]+$(sed 's/\$$//' <<<"$CODE_RE"):" | grep -vE "$VENDOR_RE" >"$tmp/todo"
  todo=$(wc -l <"$tmp/todo" | tr -d ' ')
  echo "- TODO / FIXME / HACK / XXX: $todo 件$(if ((todo > 0)); then echo "（$(grep -owE '(TODO|FIXME|HACK|XXX)' "$tmp/todo" | sort | uniq -c | sort -rn | awk '{ printf "%s%s %s", (NR > 1 ? " / " : ""), $2, $1 }')）"; fi)"
  if ((todo > 0)); then
    echo "  - 多いファイル: $(cut -d: -f1 "$tmp/todo" | sort | uniq -c | sort -rn | head -5 | awk '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1 }')"
    grep -wE '(FIXME|HACK|XXX)' "$tmp/todo" | head -6 | loc_split | sed -E 's/\t[[:space:]]*/: /' | cut -c1-150 | sed 's/^/  - /'
  fi
  local tracked big
  tracked=$(grep -oE '^(.*/)?(node_modules|vendor/bundle|dist|build|coverage|Pods|\.next|__pycache__|\.venv|venv|tmp|log)/' "$tmp/files" | sort | uniq -c | sort -rn | head -6 | awk '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1 }')
  echo "- git に入っている生成物・一時ファイルらしきディレクトリ: ${tracked:-なし}"
  local ds
  ds=$(grep -cE '(^|/)\.DS_Store$' "$tmp/files")
  ((ds > 0)) && echo "- .DS_Store: $ds 件"
  big=$(git ls-tree -r -l HEAD 2>/dev/null | awk '$4 != "-" && $4 > 1048576 { $1 = $2 = $3 = ""; s = $4; $4 = ""; sub(/^ +/, ""); printf "%.1f MB %s\n", s / 1048576, $0 }' | sort -rn | head -8)
  if [[ -n $big ]]; then
    echo "- 1 MB を超えるファイル:"
    sed 's/^/  - /' <<<"$big"
  else
    echo "- 1 MB を超えるファイル: なし"
  fi
  echo
}

section_team() {
  echo "## 7. 体制・活動"
  echo
  local commits
  commits=$(git rev-list --count --no-merges --since="12 months ago" HEAD 2>/dev/null)
  echo "- 最終コミット: $(git log -1 --format='%cs（%cr）' HEAD 2>/dev/null) ・ 直近 12 か月のコミット: ${commits:-0} 件"
  echo "- 月別コミット数: $(git log --since="12 months ago" --no-merges --format=%cs HEAD 2>/dev/null | cut -c1-7 | sort | uniq -c | awk '{ printf "%s%s: %s", (NR > 1 ? " / " : ""), $2, $1 }')"
  local authors
  authors=$(git shortlog -sn --no-merges --since="12 months ago" HEAD 2>/dev/null)
  if [[ -n $authors ]]; then
    echo "- 直近 12 か月のコミッター: $(wc -l <<<"$authors" | tr -d ' ') 人（上位: $(awk -v t="${commits:-1}" 'NR <= 5 { n = $1; $1 = ""; sub(/^ /, ""); printf "%s%s %d%%", (NR > 1 ? " / " : ""), $0, n * 100 / (t > 0 ? t : 1) }' <<<"$authors")）"
  fi
  echo
}

section_docs() {
  echo "## 8. ドキュメント・開発環境"
  echo
  local readme
  readme=$(grep -iE '^readme(\.[a-z]+)?$' "$tmp/files" | head -1)
  if [[ -n $readme ]]; then
    echo "- $readme: $(wc -l <"$readme" | tr -d ' ') 行。見出し: $(grep -E '^#{1,3} ' "$readme" | head -25 | sed -E 's/^#+ //' | tr '\n' '|' | sed 's/|$//; s/|/ | /g')"
  else
    echo "- README: なし"
  fi
  local docs
  docs=$(grep -iE '^(contributing|security|changelog|codeowners|license|code_of_conduct)(\.[a-z]+)?$|^(\.github|docs)/(contributing|security|codeowners|pull_request_template)(\.[a-z]+)?$|^\.github/(ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE)/|^\.devcontainer/' "$tmp/files" | sed -E 's#^(\.github/ISSUE_TEMPLATE|\.github/PULL_REQUEST_TEMPLATE|\.devcontainer)/.*#\1/#' | sort -u | tr '\n' ' ')
  echo "- その他のドキュメント・テンプレート: ${docs:-なし}"
  echo "- docs/ のファイル数: $(grep -cE '^docs?/' "$tmp/files")"
  local examples
  examples=$(grep -E '(^|/)\.env[^/]*\.(example|sample|template|dist)$|(^|/)\.env\.(example|sample|template)$|(^|/)example\.env$' "$tmp/files" | head -5 | tr '\n' ' ')
  echo "- 環境変数のサンプル: ${examples:-なし}"

  # コードで参照している環境変数のうち、サンプル・ドキュメント・設定ファイルのどこにも出てこないもの
  git grep -nIoE 'process\.env\.[A-Z_][A-Z0-9_]+|process\.env\[["'\''][A-Z_][A-Z0-9_]+|import\.meta\.env\.[A-Z_][A-Z0-9_]+|ENV(\.fetch\()?\[?["'\''][A-Z_][A-Z0-9_]+|os\.(environ(\.get)?\(?\[?|getenv\()["'\''][A-Z_][A-Z0-9_]+|os\.(Getenv|LookupEnv)\("[A-Z_][A-Z0-9_]+|env::var\("[A-Z_][A-Z0-9_]+|getenv\(["'\''][A-Z_][A-Z0-9_]+' 2>/dev/null |
    grep -iE "^[^:]+$(sed 's/\$$//' <<<"$CODE_RE"):" | grep -vE "$VENDOR_RE" | grep -vE "$TEST_RE" |
    sed -E 's/^([^:]+:[0-9]+):.*[^A-Z0-9_]([A-Z_][A-Z0-9_]+)$/\2\t\1/' |
    grep -vE '^(NODE_ENV|CI|HOME|PATH|PWD|USER|SHELL|TMPDIR|LANG|TZ|RAILS_ENV|RACK_ENV|DEBUG)\b' | sort -u -t$'\t' -k1,1 >"$tmp/envs"
  if [[ -s $tmp/envs ]]; then
    local names pattern undocumented
    names=$(cut -f1 "$tmp/envs")
    pattern=$(tr '\n' '|' <<<"$names" | sed 's/|$//')
    git grep -hIowE "($pattern)" -- '*.md' '*.example' '*.sample' '*.template' '*.dist' '.env*' '*.yml' '*.yaml' '*.toml' '*.json' '*.tf' '*.tfvars' '*Dockerfile*' '*.ini' '*.cfg' '*.conf' 2>/dev/null | sort -u >"$tmp/envs_doc"
    undocumented=$(awk -F'\t' 'NR == FNR { d[$0] = 1; next } !($1 in d) { print $1 "（" $2 "）" }' "$tmp/envs_doc" "$tmp/envs")
    echo "- コードが参照する環境変数: $(wc -l <"$tmp/envs" | tr -d ' ') 個。サンプル・ドキュメント・設定ファイルに出てこないもの: $(if [[ -n $undocumented ]]; then wc -l <<<"$undocumented" | tr -d ' '; else echo 0; fi) 個"
    [[ -n $undocumented ]] && head -20 <<<"$undocumented" | sed 's/^/  - /'
  fi
  local bins make
  bins=$(grep -E '^bin/[^/]+$' "$tmp/files" | head -15 | tr '\n' ' ')
  [[ -n $bins ]] && echo "- bin/: $bins"
  if [[ -f Makefile ]]; then
    make=$(grep -oE '^[A-Za-z0-9_.-]+:' Makefile | tr -d ':' | grep -v '^\.' | head -20 | tr '\n' ' ')
    echo "- Makefile のターゲット: ${make:-なし}"
  fi
  echo
}

section_layout() {
  echo "## 9. 構成"
  echo
  echo "- ルート直下のファイル: $(grep -v / "$tmp/files" | head -50 | tr '\n' ' ')"
  echo "- ディレクトリ（2 階層目まで。数字は配下のファイル数）:"
  awk -F/ 'NF > 1 { print $1 "/"; if (NF > 2) print $1 "/" $2 "/" }' "$tmp/files" | sort | uniq -c |
    awk '{ printf "  - %s (%s)\n", $2, $1 }' | head -60
}

wait
{
  section_overview
  section_versions
  section_security
  section_ci
  section_deps
  section_quality
  section_code
  section_team
  section_docs
  section_layout
} | tee "$out"
echo
echo "（この材料は $out にも保存した）"
