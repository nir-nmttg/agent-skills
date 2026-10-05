#!/usr/bin/env bash
# 標準入力の健康診断レポート（Markdown）を保存し、Mermaid 図入りの HTML にしてローカルサーバーで配信する。
#
# 使い方: publish-report.sh <レポート ID> [--open] [--saved] <<'__REPORT__'
#         （レポートの Markdown）
#         __REPORT__
#   --open   既定のブラウザでも開く（Claude の組み込みブラウザが使えないとき用）
#   --saved  標準入力は使わず、保存済みの今日の .md から HTML を作り直す（.md を直接直したあと用）
#
# レポート ID は collect.sh が出す owner/repo（GitHub のリモートがなければ local/<フォルダ名>）。
# 保存先は $REPO_CHECKUP_DIR（既定: ~/repo-checkups）/<レポート ID>/<日付>.md と .html。
# file:// で開くと組み込みブラウザでは図が描画されないため、127.0.0.1 の簡易サーバーで配信する（12 時間で自動停止）。
set -euo pipefail

usage() { sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

id=${1:-} open="" saved=""
[[ $id =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
shift
for opt in "$@"; do
  case $opt in
    --open) open=1 ;;
    --saved) saved=1 ;;
    *) usage ;;
  esac
done

root=${REPO_CHECKUP_DIR:-$HOME/repo-checkups}
dir="$root/$id"
mkdir -p "$dir"
today=$(date +%F)
md="$dir/$today.md" html="$dir/$today.html"

if [[ -n $saved ]]; then
  [[ -s $md ]] || { echo "保存済みのレポートがありません: $md" >&2; exit 1; }
else
  report=$(cat)
  if [[ -z ${report//[[:space:]]/} ]]; then
    echo "レポートの Markdown を標準入力で渡してください。" >&2
    exit 1
  fi
  printf '%s\n' "$report" >"$md"
fi

# Markdown を JS の文字列として埋め込む。< はエスケープし、本文中の </script> などで HTML が壊れないようにする
template="$(dirname "$0")/../assets/report.html"
jq -Rrs --rawfile tpl "$template" '
  (tojson | gsub("<"; "\\u003c")) as $json
  | $tpl | split("__REPORT_JSON__") | .[0] + $json + .[1]' "$md" >"$html"

# 自分が立てたサーバーかどうかを見分けるための目印
marker="$root/.repo-checkup-server"
[[ -s $marker ]] || echo "repo-checkup-server $RANDOM$RANDOM" >"$marker"
token=$(cat "$marker")

port=""
for p in $(seq "${REPO_CHECKUP_PORT:-47331}" "$((${REPO_CHECKUP_PORT:-47331} + 9))"); do
  if [[ $(curl -fs --max-time 1 "http://127.0.0.1:$p/.repo-checkup-server" 2>/dev/null) == "$token" ]]; then
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
      if [[ $(curl -fs --max-time 1 "http://127.0.0.1:$p/.repo-checkup-server" 2>/dev/null) == "$token" ]]; then
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
url="http://127.0.0.1:$port/$id/$today.html"
echo "表示: $url"

if [[ -n $open ]]; then
  if command -v open >/dev/null; then open "$url"; elif command -v xdg-open >/dev/null; then xdg-open "$url"; fi
fi
