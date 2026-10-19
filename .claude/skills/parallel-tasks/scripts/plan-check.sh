#!/usr/bin/env bash
# 並列化の計画（plan.json）を確かめ、実行の順番と作業ごとの指示書を作る。
#
# 使い方: plan-check.sh <計画フォルダ>
#   対象のリポジトリは plan.json の repo（省略時は今のフォルダ）。ファイルの重なりを、その中のファイルの一覧で調べる
#
# 計画フォルダの plan.json を読み、次を確かめる。
#   - id・runner・title・files・depends_on の書き方と、依存の循環
#   - 書き込む作業どうしで、依存の順がついていないのに触るファイルが重なっていないか
# 問題がなければ、実行の順番（段）・最長の道筋・注意点を出力し、briefs/<id>.md に指示書を書く（self の作業は除く）。
# 指示書には、計画フォルダの results/<依存先の id>.md（終わった作業の報告）があればその中身も入れる。
# 問題があれば内容を出力して終了コード 1 で終わる（指示書は書かない）。
set -euo pipefail

usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

(($# == 1)) || usage
dir=$(cd "$1" && pwd)
plan="$dir/plan.json"
[[ -f $plan ]] || { echo "plan.json がありません: $plan" >&2; exit 1; }
jq empty "$plan" 2>/dev/null || { echo "plan.json を JSON として読めません: $plan" >&2; exit 1; }
repo=$(jq -r 'if (.repo | type) == "string" then .repo else "." end' "$plan")
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || { echo "repo が git リポジトリではありません: $repo" >&2; exit 1; }
repo=$top

script_dir=$(cd -P "$(dirname "$0")" && pwd)
skill_dir=$(dirname "$script_dir")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$repo" ls-files -co --exclude-standard >"$tmp/files" 2>/dev/null || : >"$tmp/files"

# 今のフォルダと対象のリポジトリが違うか（別セッションの提案カードには作業するフォルダを付けられない）
here=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
other_repo=false
[[ $(cd -P "$here" && pwd) == $(cd -P "$repo" && pwd) ]] || other_repo=true

result=$(jq -L "$script_dir" --rawfile files "$tmp/files" --argjson other_repo "$other_repo" '
  include "plan";
  ($files | split("\n") | map(select(length > 0))) as $files
  | . as $plan
  | (if (.tasks | type) == "array" then .tasks else [] end) as $T
  | [
      (if (.tasks | type) != "array" then "tasks は配列にします" else empty end),
      ($T[] | select(type != "object") | "tasks の要素はオブジェクトにします"),
      ($T[] | objects | . as $t | ("files", "depends_on", "done", "verify", "notes")
            | select(($t[.] // []) | type != "array") | "\($t.id): \(.) は配列にします"),
      ($T[] | objects | select((.est_min // 0) | type != "number") | "\(.id): est_min は数（分）にします"),
      (($plan.contracts // []) | if type != "array" then "contracts は配列にします"
                                 else .[] | select((.file | type) != "string") | "contracts の要素には file（パス）を書きます" end),
      (($plan.decisions // []) | select(type != "array") | "decisions は配列にします")
    ] as $type_errors
  | if ($type_errors | length) > 0 then {errors: $type_errors} else
    ($T | map(.id)) as $ids
  | [
      (if ($T | length) == 0 then "tasks に作業が 1 つもありません" else empty end),
      ($T[] | select((.id | type) != "string" or (.id | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$") | not))
            | "id は英数字・ハイフン・下線の 60 文字までにします（今: \(.id // "なし")）"),
      ($ids | map(tostring) | group_by(.) | map(select(length > 1) | .[0])[] | "id が重複しています: \(.)"),
      ($T[] | select(.runner as $r | runners | index($r) | not)
            | "\(.id): runner は self / explore / codex / session のどれかにします（今: \(.runner // "なし")）"),
      ($T[] | select((.title // "") == "") | "\(.id): title がありません"),
      ($T[] | select(writes and ((.files // []) | length) == 0) | "\(.id): ファイルを書き込む作業なので、files に触るファイルを書きます"),
      ($T[] | .id as $id | (.depends_on // [])[] | select(. == $id) | "\($id): 自分自身に依存しています"),
      ($T[] | .id as $id | (.depends_on // [])[] | select(. as $d | $ids | index($d) | not) | "\($id): 依存先の \(.) がありません")
    ] as $errors
  | if ($errors | length) > 0 then {errors: $errors}
    else
      ($plan | levels) as $lv
      | if ($lv.cycle | length) > 0 then {errors: ["依存が循環しています: \($lv.cycle | join("、"))"]}
        else
          ($plan | ancestors($lv.waves)) as $anc
          | ($plan | critical($lv.waves)) as $crit
          | ($T | map({key: .id, value: .}) | from_entries) as $byid
          | [
              range(0; $T | length) as $i | range($i + 1; $T | length) as $j
              | $T[$i] as $a | $T[$j] as $b
              | select(($a | writes) and ($b | writes) and ([$a.runner, $b.runner] != ["self", "self"]))
              | select(($anc[$a.id] | index($b.id) | not) and ($anc[$b.id] | index($a.id) | not))
              | [$a.files[] as $fa | $b.files[] as $fb | select(overlaps($fa; $fb; $files)) | "\($fa) と \($fb)"] as $hits
              | select(($hits | length) > 0)
              | "\($a.id) と \($b.id) の触るファイルが重なります（\($hits[:3] | join("、"))）。ファイルを分けるか、depends_on で順番をつけます"
            ] as $conflicts
          | if ($conflicts | length) > 0 then {errors: $conflicts}
            else
              ([$lv.waves[] | length] | max) as $width
              | [
                  (if $width < 2 then "同時に進められる作業が 1 つしかありません。並列にする効果がないので、分けずに順番に進めます" else empty end),
                  ($lv.waves | to_entries[]
                    | (.key + 1) as $n | [.value[] | select($byid[.].runner == "codex")] as $c
                    | select(($c | length) > 4)
                    | "\($n) 段目で Luna が \($c | length) 本同時に動きます。4 本までにして、終わった分から次を動かします"),
                  ([$T[] | select(.runner == "session")] | length | select(. > 4)
                    | "別セッションが \(.) 本あります。1 回に提案するのは 4 本までにします"),
                  ($T[] | select(.runner == "session" and ((.depends_on // []) | length) > 0)
                    | "\(.id): 別セッションはこの作業フォルダの未コミットの変更を見られません（ブランチの先端から始まる）。依存先の結果が要るなら self か codex にします"),
                  ($T[] | .id as $id | select(.runner == "session")
                    | [$T[] | select((.depends_on // []) | index($id)) | .id] as $dependents
                    | select(($dependents | length) > 0)
                    | "\($id): 別セッションの結果がこの作業フォルダに入るのはマージしてからなので、依存する \($dependents | join("、")) が止まります"),
                  (if $other_repo and any($T[]; .runner == "session")
                   then "repo が今のフォルダと違うので、別セッションの提案カードは出せません。session の作業は self か codex にします" else empty end),
                  (if (($plan.contracts // []) | length) > 0 and any($T[]; .runner == "session")
                   then "共通部分（contracts）は、コミットするまで別セッションからは見えません" else empty end),
                  (($plan.contracts // [])[] as $c | $T[] | select(writes and any(.files[]; overlaps(.; $c.file; $files)))
                    | "\(.id) が共通部分の \($c.file) を変えます。ほかの作業の前提が崩れないか確かめます"),
                  (if any($T[]; .runner == "self") then empty
                   else "Claude 本体（self）の担当がありません。待つ間に進められる作業（最長の道筋の上のものなど）を self にすると早く終わります" end)
                ] as $warnings
              | {
                  errors: [],
                  warnings: $warnings,
                  goal: ($plan.goal // ""),
                  counts: ($T | group_by(.runner) | map({key: .[0].runner, value: length}) | from_entries),
                  waves: [$lv.waves[] | map({id: ., runner: $byid[.].runner})],
                  critical: $crit,
                  briefs: [$T[] | select(.runner != "self") | .id]
                }
            end
        end
    end
  end
' "$plan")

if [[ $(jq '.errors | length' <<<"$result") -gt 0 ]]; then
  echo "計画に問題があります（plan.json を直して、もう一度実行します）:"
  jq -r '.errors[] | "  - \(.)"' <<<"$result"
  exit 1
fi

# 作業ごとの指示書を書く
mkdir -p "$dir/briefs"
rm -f "$dir"/briefs/*.md
template="$skill_dir/assets/brief.md"
# 終わった作業の報告（results/<id>.md）を {id: 中身} にまとめる
results='{}'
for f in "$dir"/results/*.md; do
  [[ -f $f ]] || continue
  results=$(jq -Rs --argjson acc "$results" --arg id "$(basename "$f" .md)" '$acc + {($id): .}' "$f")
done
for id in $(jq -r '.briefs[]' <<<"$result"); do
  jq -r -L "$script_dir" --arg id "$id" --arg repo "$repo" --rawfile tpl "$template" --argjson results "$results" '
    include "plan";
    def bullets: if length == 0 then "- なし" else map("- \(.)") | join("\n") end;
    def code_bullets: if length == 0 then "- なし" else map("- `\(.)`") | join("\n") end;
    . as $plan
    | (.tasks | map({key: .id, value: .}) | from_entries) as $byid
    | $byid[$id] as $t
    | ($t | writes) as $w
    | (levels.waves) as $waves
    | ancestors($waves) as $anc
    # 同時に動きうる作業（依存の順がついていない作業）
    | [.tasks[] | select(.id != $id and (.id as $o | ($anc[$id] | index($o) | not) and ($anc[$o] | index($id) | not)))] as $concurrent
    | {
        id: $t.id,
        title: $t.title,
        plan_goal: ($plan.goal // "（書かれていない）"),
        goal: ($t.goal // $t.title),
        # Explore は Claude の作業フォルダで動くので絶対パスを渡す。codex と session は専用の worktree で動く
        repo: (if $w then "今の作業フォルダ（このリポジトリの専用の worktree）。ファイルのパスはここからの相対で書いてある"
               else "`\($repo)`。ファイルのパスはここからの相対で書いてある。このフォルダの中だけを調べる" end),
        files_heading: (if $w then "触ってよいファイル" else "読む範囲" end),
        files: (($t.files // []) | if length == 0 then "- 指定なし（目的に必要な範囲だけ読む）" else code_bullets end),
        not_files: (if $w
                    then [$concurrent[] | select(writes) | .files[]] | unique | code_bullets
                    else "- すべて（読むだけで、ファイルは作成・変更しない）" end),
        premises: ([
            (($plan.contracts // [])[] | "`\(.file)`: \(.what // "共通部分")（先に用意してある。中身は変えない）"),
            (($t.depends_on // [])[] | "`\(.)`（\($byid[.].title)）は終わっている"
                                       + (if $byid[.] | writes then "。その変更は作業フォルダに入っている" else "" end)
                                       + (if $results[.] then "。報告は下の「依存先の結果」" else "" end))
          ] | bullets),
        results: ([($t.depends_on // [])[] | select($results[.]) | "### \(.)（\($byid[.].title)）\n\n\($results[.] | rtrimstr("\n"))"]
                  | if length == 0 then "なし" else join("\n\n") end),
        decisions: (($plan.decisions // []) | bullets),
        notes: (($t.notes // []) | bullets),
        done: (($t.done // []) | bullets),
        verify: (($t.verify // []) | code_bullets),
        rules: ((if $w then [
                  "「触ってよいファイル」以外は変えない。必要になったら変えずに、報告の「未解決の点」に書く",
                  "先に用意してある共通部分の中身は変えない"
                ] else [
                  "ファイルを作成・変更しない（読むだけ）",
                  "調べるのは目的に必要な範囲だけにする"
                ] end)
                + (if $t.runner == "session" then ["自分のブランチへのコミットまではしてよい。push・PR の作成・ほかのブランチのマージはしない"] else [] end)
                + ["秘密情報（トークン、パスワード、個人情報）を書かない"]
                | bullets),
        report: (if $w then
"### 結果
完了 / 一部完了 / 失敗 のどれか

### 変えたファイル
1 ファイル 1 行で、何をしたか

### 確認したこと
実行したコマンドと結果

### 未解決の点・判断したこと
なければ「なし」"
                 else
"### 結論
3 行以内

### 根拠
`path:line` と 1 行の説明。10 個まで

### 未確認・推測の点
なければ「なし」" end)
      }
    | reduce to_entries[] as $e ($tpl; split("{{\($e.key)}}") | join($e.value | tostring))
  ' "$plan" >"$dir/briefs/$id.md"
done

next_cmd=$(printf '%q ' bash "$script_dir/next.sh" "$dir" | sed 's/ $//')
jq -r -L "$script_dir" --arg dir "$dir" --arg next_cmd "$next_cmd" '
  include "plan";
  "計画: \(if .goal == "" then "（goal が書かれていない）" else .goal end)",
  "作業: \([.waves[][]] | length) 本（\(.counts | to_entries | map("\(.key | runner_label) \(.value)") | join("・"))）",
  "",
  "実行の順番（段は目安。依存が終わった作業から順に始める）:",
  (.waves | to_entries[] | "  \(.key + 1) 段目: \(.value | map("\(.id)（\(.runner | runner_label)）") | join("、"))"),
  "最長の道筋: \(.critical.path | join(" → "))（見積もり 約 \(.critical.minutes) 分）",
  (if (.warnings | length) > 0 then "", "注意:", (.warnings[] | "  - \(.)") else empty end),
  "",
  (if (.briefs | length) > 0 then "指示書:", (.briefs[] | "  \(.): \($dir)/briefs/\(.).md") else empty end),
  "",
  "今すぐ始められる作業を出す: \($next_cmd)"
' <<<"$result"
