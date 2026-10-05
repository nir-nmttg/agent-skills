#!/usr/bin/env bash
# 標準入力の実装計画（Markdown）を保存し、Mermaid 図入りの HTML にしてローカルサーバーで配信する。
#
# 使い方: publish-plan.sh <owner/repo> <Issue 番号> [--open] [--saved] <<'__PLAN__'
#         （計画の Markdown）
#         __PLAN__
#   --open   既定のブラウザでも開く（Claude の組み込みブラウザが使えないとき用）
#   --saved  標準入力は使わず、保存済みの .md から HTML を作り直す（.md を直接直したあと用）
#
# 保存先は $ISSUE_PLAN_DIR（既定: ~/issue-plans）/<owner>/<repo>/<番号>.md と .html。
# file:// で開くと組み込みブラウザでは図が描画されないため、127.0.0.1 の簡易サーバーで配信する（12 時間で自動停止）。
set -euo pipefail

usage() { sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

repo=${1:-} number=${2:-} open="" saved=""
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $number =~ ^[0-9]+$ ]] || usage
shift 2
for opt in "$@"; do
  case $opt in
    --open) open=1 ;;
    --saved) saved=1 ;;
    *) usage ;;
  esac
done

root=${ISSUE_PLAN_DIR:-$HOME/issue-plans}
dir="$root/$repo"
mkdir -p "$dir"
md="$dir/$number.md" html="$dir/$number.html"

if [[ -n $saved ]]; then
  [[ -s $md ]] || { echo "保存済みの計画がありません: $md" >&2; exit 1; }
else
  plan=$(cat)
  if [[ -z ${plan//[[:space:]]/} ]]; then
    echo "計画の Markdown を標準入力で渡してください。" >&2
    exit 1
  fi
  printf '%s\n' "$plan" >"$md"
fi

# Markdown を JS の文字列として埋め込む。< はエスケープし、本文中の </script> などで HTML が壊れないようにする
template="$(dirname "$0")/../assets/plan.html"
jq -Rrs --rawfile tpl "$template" '
  (tojson | gsub("<"; "\\u003c")) as $json
  | $tpl | split("__PLAN_JSON__") | .[0] + $json + .[1]' "$md" >"$html"

# 自分が立てたサーバーかどうかを見分けるための目印
marker="$root/.issue-plan-server"
[[ -s $marker ]] || echo "issue-plan-server $RANDOM$RANDOM" >"$marker"
token=$(cat "$marker")

port=""
for p in $(seq "${ISSUE_PLAN_PORT:-47321}" "$((${ISSUE_PLAN_PORT:-47321} + 9))"); do
  if [[ $(curl -fs --max-time 1 "http://127.0.0.1:$p/.issue-plan-server" 2>/dev/null) == "$token" ]]; then
    port=$p
    break
  fi
  if ! nc -z 127.0.0.1 "$p" 2>/dev/null; then
    nohup python3 - "$p" "$root" >/dev/null 2>&1 <<'PY' &
import functools, http.server, sys, threading

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

port, root = int(sys.argv[1]), sys.argv[2]
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=root))
threading.Timer(12 * 60 * 60, server.shutdown).start()
server.serve_forever()
PY
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.3
      if [[ $(curl -fs --max-time 1 "http://127.0.0.1:$p/.issue-plan-server" 2>/dev/null) == "$token" ]]; then
        port=$p
        break 2
      fi
    done
  fi
done

echo "保存: $md"
if [[ -z $port ]]; then
  echo "ローカルサーバーを起動できませんでした。HTML をブラウザで直接開いてください: $html" >&2
  exit 1
fi
url="http://127.0.0.1:$port/$repo/$number.html"
echo "表示: $url"

if [[ -n $open ]]; then
  if command -v open >/dev/null; then open "$url"; elif command -v xdg-open >/dev/null; then xdg-open "$url"; fi
fi
