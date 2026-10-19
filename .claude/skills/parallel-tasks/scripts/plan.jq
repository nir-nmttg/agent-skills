# plan-check.sh と next.sh で共有する jq の関数。`jq -L <scripts のフォルダ> 'include "plan"; ...'` で使う。

def runners: ["self", "explore", "codex", "session"];

# ファイルを書き込む作業か（explore は読むだけ）
def writes: .runner != "explore";

# 見積もり（分）。書かれていなければ 15 分とみなす
def est: (.est_min // 15);

# id → 依存先の一覧（存在しない id は除く）
def deps_map:
  (.tasks | map(.id)) as $ids
  | .tasks | map({key: .id, value: [(.depends_on // [])[] | select(. as $d | $ids | index($d))]}) | from_entries;

# --- ファイルのパターン --------------------------------------------------------

def re_escape: gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)");
def norm_path: sub("^\\./"; "") | if endswith("/") then . + "**" else . end;
def is_glob: test("[*?]");
def literal_prefix: capture("^(?<p>[^*?]*)").p;

# パターンを、当てはまるパスの正規表現にする。glob でないパスは、そのファイルとその下すべてに当たる
def path_re:
  norm_path
  | if is_glob then
      "^" + (re_escape
             | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
             | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
             | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")) + "$"
    else "^" + re_escape + "(/.*)?$" end;

# 2 つのパターンが同じファイルを指しうるか。$files はリポジトリのファイルの一覧
# 一覧の中に両方に当たるファイルがあれば重なる。まだないファイルについては、片方がもう片方を含むフォルダ
# （glob でないパスか「フォルダ/**」）のときか、** を含む glob がもう片方のフォルダの上から当たりうるときに重なるとみなす
def overlaps($a0; $b0; $files):
  ($a0 | norm_path) as $a | ($b0 | norm_path) as $b
  | ($a | path_re) as $ra | ($b | path_re) as $rb
  # dir_of: glob でないパスか「フォルダ/**」なら、そのフォルダ（末尾に /）。それ以外は null
  | def dir_of: if is_glob | not then . + "/" elif endswith("/**") and (.[:-2] | is_glob | not) then .[:-2] else null end;
    ($a | dir_of) as $da | ($b | dir_of) as $db
  | $a == $b
    or (($a | is_glob | not) and ($a | test($rb)))
    or (($b | is_glob | not) and ($b | test($ra)))
    or ($da != null and ($b | literal_prefix | startswith($da)))
    or ($db != null and ($a | literal_prefix | startswith($db)))
    # ** を含む glob は、接頭辞より下のどのフォルダにも当たりうる
    or ($da != null and ($b | contains("**")) and ($da | startswith($b | literal_prefix)))
    or ($db != null and ($a | contains("**")) and ($db | startswith($a | literal_prefix)))
    or any($files[]; test($ra) and test($rb));

# --- 依存の順番 ----------------------------------------------------------------

# 依存の段（Kahn 法）。{waves: [[id...]...], cycle: [循環して並べられなかった id...]}
def levels:
  deps_map as $deps
  | {done: [], waves: [], rest: (.tasks | map(.id)), stuck: false}
  | until((.rest | length) == 0 or .stuck;
      .done as $d
      | [.rest[] | select(($deps[.] - $d | length) == 0)] as $ready
      | if ($ready | length) == 0 then .stuck = true
        else .waves += [$ready] | .done += $ready | .rest -= $ready end)
  | {waves, cycle: .rest};

# id → その作業より先に終わっていなければならない作業（依存をたどったすべて）
def ancestors($waves):
  deps_map as $deps
  | reduce ($waves | flatten[]) as $id ({};
      .[$id] = ([$deps[$id][] as $p | $p, (.[$p] // [])[]] | unique));

# 見積もりの合計がいちばん長い依存の道筋。{minutes, path: [id...]}
def critical($waves):
  deps_map as $deps
  | (.tasks | map({key: .id, value: est}) | from_entries) as $est
  | reduce ($waves | flatten[]) as $id ({};
      ([$deps[$id][] as $p | {p: $p, d: .[$p].d}] | max_by(.d)) as $best
      | .[$id] = {d: (($best.d // 0) + $est[$id]), prev: $best.p})
  | . as $dist
  | (to_entries | max_by(.value.d)) as $end
  | {minutes: $end.value.d,
     path: ([$end.key] | until($dist[.[0]].prev == null; [$dist[.[0]].prev] + .))};

def runner_label:
  {self: "Claude 本体", explore: "Explore", codex: "Luna", session: "別セッション"}[.] // .;
