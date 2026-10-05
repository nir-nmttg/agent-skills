#!/usr/bin/env bash
# 言語・フレームワーク・OS などのバージョンを endoflife.date と照らし、サポート期限の表（Markdown）を出力する。
#
# 使い方: <TSV> | eol.sh
#   入力は 1 行 1 件「場所<TAB>製品<TAB>バージョン指定」。製品は endoflife.date の ID（nodejs, rails など）
#   例: printf 'Dockerfile:1\tnodejs\t18-alpine\n' | eol.sh
set -euo pipefail

input=$(grep -v '^[[:space:]]*$' || true)
if [[ -z $input ]]; then
  echo "（バージョン指定は見つからなかった）"
  exit 0
fi

cache=$(mktemp -d)
trap 'rm -rf "$cache"' EXIT

# 製品ごとのサポート情報を並列で取得する
for p in $(cut -f2 <<<"$input" | sort -u); do
  [[ $p =~ ^[a-z0-9.-]+$ ]] || continue
  curl -fsS --max-time 15 "https://endoflife.date/api/$p.json" -o "$cache/$p.json" 2>/dev/null &
done
wait || true

echo '{}' >"$cache/all"
for f in "$cache"/*.json; do
  [[ -s $f ]] || continue
  p=$(basename "$f" .json)
  jq --arg p "$p" --slurpfile c "$f" '. + {($p): $c[0]}' "$cache/all" >"$cache/next" && mv "$cache/next" "$cache/all"
done

jq -Rrn --slurpfile all "$cache/all" '
  $all[0] as $data
  | def days($d): ((($d + "T00:00:00Z") | fromdateiso8601) - now) / 86400 | floor;
    # 指定に合うサイクルを探す: 完全一致（ubuntu-22.04 など）→ コードネーム（bookworm など）→ 数字の前方一致（最長）→ 「8」なら 8.x の最新
    def cycle($cycles; $raw):
      ($raw | ascii_downcase) as $r
      | ([$raw | scan("[0-9]+(?:\\.[0-9]+)*")] | .[0] // "") as $v
      | ($cycles | map(select((.cycle | tostring | ascii_downcase) == $r)) | .[0])
        // ($cycles | map(select((.codename // "" | ascii_downcase | split(" ") | .[0] // "") as $c
              | $c != "" and ($r | test("(^|[^a-z])" + $c + "($|[^a-z])"))))
            | .[0])
        // (if $v == "" then null else
              ($cycles | map(select((.cycle | tostring) as $c | $v == $c or ($v | startswith($c + "."))))
                | max_by(.cycle | tostring | length))
              // ($cycles | map(select(.cycle | tostring | startswith($v + "."))) | .[0])
            end);
    # Lambda は eol が「更新できなくなる日」なので、非推奨になる日（support）で判定する
    def judge($c; $product):
      (if $product == "aws-lambda" and ($c.support | type) == "string" then $c.support else $c.eol end) as $end
      | if $c == null then {rank: 2, text: "❔ 判定できず"}
        elif $end == true then {rank: 0, text: "🔴 終了済み"}
        elif ($end | type) != "string" then {rank: 3, text: "🟢 サポート中"}
        else days($end) as $d
          | if $d < 0 then {rank: 0, text: "🔴 終了済み（\($end)）"}
            elif $d <= 180 then {rank: 1, text: "🟡 あと \($d) 日（\($end)）"}
            else {rank: 3, text: "🟢 〜\($end)"} end
        end;

  [inputs | split("\t") | select(length >= 3) | {loc: .[0], product: .[1], raw: .[2]}]
  | map(. as $x
      | $data[$x.product] as $cycles
      | (if $cycles then cycle($cycles; $x.raw) else null end) as $c
      | $x + {
          cycle: ($c.cycle // null),
          judge: (if $cycles then judge($c; $x.product) else {rank: 2, text: "❔ 情報を取得できず"} end),
          # 系列が混在する製品（Actions のランナー、Lambda）では「最新」を出さない
          latest: (if $cycles and ($x.product | IN("github-actions-runner-images", "aws-lambda") | not)
                   then ($cycles[0].cycle | tostring) else "—" end)
        })
  | group_by([.product, (.cycle // .raw)])
  | map(.[0] + {locs: (map(.loc) | unique), raws: (map(.raw) | unique)})
  | sort_by(.judge.rank, .product)
  | "| 製品 | 指定 | 判定 | 最新 | 場所 |",
    "| --- | --- | --- | --- | --- |",
    (.[] | "| \(.product) | \(.raws[:3] | join(" / ")) | \(.judge.text) | \(.latest) | \(.locs[:3] | join("<br>"))\(if (.locs | length) > 3 then "<br>ほか \((.locs | length) - 3) 件" else "" end) |")
' <<<"$input"
