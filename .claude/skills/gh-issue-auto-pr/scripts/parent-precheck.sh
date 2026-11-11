#!/usr/bin/env bash
# 親ディレクトリのモードの入口の確認（precheck.sh が、親ディレクトリで実行されたときに呼ぶ）。
# 配下のリポジトリ（repos.sh の REPO_DEPTH 階層まで）を読むだけで調べ、子のセッションに任せるリポジトリを 1 つ決めるか、終えると決める。
# Issue・ブランチ・リポジトリのファイルは変えない（記録は lib.sh の parent_state_dir に書く）。
#
# 使い方: parent-precheck.sh [--label <ラベル>] [--result <結果の 1 行目>]
#         parent-precheck.sh --check-one <パス> <owner/name> [--label <ラベル>]   # 1 つのリポジトリを調べる（内部用）
#   出力（固定の形）:
#     - モード: 親ディレクトリ                 （必ず最初に出す）
#     - 判定: 子のセッションを起動する | 終える
#     - リポジトリ: <メインの checkout のパス>   （起動するとき）
#     - 名前: <owner/name>                     （起動するとき）
#     - Issue: #<番号>                         （起動するとき。古いロックの引き継ぎのときは出さない）
#     - 結果: <結果の 1 行目>                  （終えるとき。記録済み）
#     - 通知: する | しない                    （終えるとき）
#     - 追加の通知: <1 行>                     （ほかにも通知が要る問題があるとき。記録済みなので、入口が必ず送る）
#     ## 報告
#   「全体で 1 件」: どれかのリポジトリのロックが使用中なら、新しく起動しない（子のセッション・Auto-fix・手動の実行が動いている）。
#   リポジトリの問題は、親の記録（record-result.sh --parent --repo）にリポジトリごとに書く。リポジトリの .git の記録は子のセッションだけが書く。
#   起動すると決めたら、起動の予約（親の記録の delegated）をここで書く。入口は、起動に失敗したら record-result.sh --clear-delegated で消す。
#   次の回に、予約のあとに子のセッションの記録（リポジトリの .git の last-result）が更新されていなければ「動いた形跡がない」とし、
#   そのリポジトリには DELEGATE_RETRY のあいだ起動しない。
#   時間内に調べきれなかったリポジトリは、次の回に先頭から調べる（親の記録の cursor）。
# 終了コード: 0 = 判定を出した、1 = エラー（入口は手順に進まず 🔧 precheck で終える）
set -euo pipefail
echo "- モード: 親ディレクトリ"
DIR=$(cd -P "$(dirname "$0")" && pwd)
source "$DIR/lib.sh"

CHECK_LIMIT=240   # リポジトリごとの確認の上限（秒）
PHASE_LIMIT=300   # 全部のリポジトリの確認にかける上限（秒）
LIST_LIMIT=150    # Auto-fix の PR の一覧にかける上限（秒）
JOBS=4            # 同時に調べるリポジトリの数
START_GRACE=900   # 子のセッションを起動してから、動いた形跡を求めるまでの猶予（秒）
DELEGATE_RETRY=21600   # 子のセッションが動いた形跡がなかったリポジトリに、次に起動するまでの間隔（秒）
T=$'\t'

# --- 1 つのリポジトリを調べる（内部用。with_limit から呼ぶ） ---
# 出力の行（タブ区切り）: nwo <owner/name> / skip <理由> / target <番号> <作成時刻> / none / no-label /
#   problem <🔧 の 1 行> / info <報告に書く 1 行>
check_one() {
  local path=$1 name=$2 info nwo fork perm dirty out rc reason
  shift 2
  cd "$path"
  if ! info=$(gh repo view "$name" --json nameWithOwner,isFork,viewerPermission 2>&1); then
    printf 'problem\t🔧 find: リポジトリの情報を取得できない（%s）\n' "$(one_line <<<"$info")"
    return
  fi
  nwo=$(jq -r '.nameWithOwner | ascii_downcase' <<<"$info")
  fork=$(jq -r .isFork <<<"$info")
  perm=$(jq -r '.viewerPermission // ""' <<<"$info")
  printf 'nwo\t%s\n' "$nwo"
  if [[ $fork == true ]]; then printf 'skip\tfork\n'; return; fi
  case $perm in
    ADMIN | MAINTAIN | WRITE) ;;
    *) printf 'skip\t書き込みの権限がない（%s）\n' "${perm:-不明}"; return ;;
  esac
  dirty=$(git --no-optional-locks -c core.fsmonitor=false status --porcelain 2>/dev/null | head -1 || true)
  if out=$(bash "$DIR/find-issue.sh" --check --no-label-ok "$@" 2>&1); then rc=0; else rc=$?; fi
  while IFS= read -r line; do
    case $line in
      "check: skipped "*) printf 'info\t着手中か、ドラフト PR がある Issue: %s\n' "${line#check: skipped }" ;;
      "check: waiting "*) printf 'info\t止めた Issue（更新待ち）: %s\n' "${line#check: waiting }" ;;
    esac
  done <<<"$out"
  if ((rc == 0)) && grep -qE '^check: target [1-9][0-9]* ' <<<"$out"; then
    if [[ -n $dirty ]]; then
      printf 'problem\t🔧 sync: メインの checkout に未コミットの変更がある\n'
    else
      line=$(grep -E '^check: target [1-9][0-9]* ' <<<"$out" | head -1)
      line=${line#check: target }
      printf 'target\t%s\t%s\n' "${line%% *}" "${line#* }"
    fi
  elif ((rc == 0)) && grep -qx 'check: none' <<<"$out"; then
    echo none
    [[ -z $dirty ]] || printf 'info\tメインの checkout に未コミットの変更がある\n'
  elif ((rc == 0)) && grep -qx 'check: no-label' <<<"$out"; then
    echo no-label
  else
    reason=$(grep -v '^check: ' <<<"$out" | one_line)
    printf 'problem\t🔧 find: %s\n' "${reason:-Issue を探せなかった（終了コード $rc）}"
  fi
}

if [[ ${1:-} == --check-one ]]; then
  (($# >= 3)) || die "使い方: parent-precheck.sh --check-one <パス> <owner/name> [--label <ラベル>]"
  shift
  check_one "$@"
  exit 0
fi

LABEL_ARGS=() LABEL=agent:auto-pr FORCED=
while (($#)); do
  case $1 in
    --result)
      [[ -n ${2:-} ]] || die "--result に結果の 1 行目を指定してください。"
      FORCED=$2
      shift 2
      ;;
    --label)
      [[ -n ${2:-} ]] || die "--label にラベル名を指定してください。"
      LABEL_ARGS=(--label "$2") LABEL=$2
      shift 2
      ;;
    *) die "不明な引数: $1" ;;
  esac
done

PARENT=$(pwd -P)
STATE=$(parent_state_dir "$PARENT")
tmp=$(mktemp -d)
# 同じ親ディレクトリの実行どうしが重ならないようにする（手動の実行と定期実行が重なると、どちらも予約の前に調べて、子を 2 つ起動するため）。
# 止まった実行の残りは、RUN_STALE 分で引き継ぐ
RUN_STALE=20
running=
if mkdir "$STATE/running" 2>/dev/null || { [[ -n $(find "$STATE/running" -maxdepth 0 -mmin +"$RUN_STALE" 2>/dev/null) ]] && rm -rf "$STATE/running" && mkdir "$STATE/running" 2>/dev/null; }; then
  running=$STATE/running
fi
trap 'rm -rf "$tmp"; [[ -z $running ]] || rm -rf "$running"' EXIT

report=()
extra=()   # 通知が要るリポジトリの問題（表示用の 1 行）
verdict= result= notify= parent_line=

# 親の記録に書き、通知するかを返す（する / しない）
record_parent() {
  local rec
  rec=$(bash "$DIR/record-result.sh" --parent "$PARENT" "$1" 2>&1) || { echo 記録できない; return; }
  case $rec in "通知: する"*) echo する ;; *) echo しない ;; esac
}
# リポジトリの問題を親の記録に書き、通知するかを返す
record_repo() {
  local rec
  rec=$(bash "$DIR/record-result.sh" --parent "$PARENT" --repo "$1" "$2" 2>&1) || { echo 記録できない; return; }
  case $rec in "通知: する"*) echo する ;; *) echo しない ;; esac
}
# リポジトリの親の記録（なければ空）
repo_record() { cat "$STATE/repos/$(repo_key "$1")/last-result" 2>/dev/null || true; }
# リポジトリの問題を記録し、通知が要れば extra に足す。表示はリポジトリ名を入れた形にする
repo_problem() {
  local name=$1 line=$2 shown n
  shown="${line%%:*}: ${name#*/}:${line#*:}"
  report+=("- ${name#*/}: $line")
  n=$(record_repo "$name" "$line")
  [[ $n != する && $n != 記録できない ]] || extra+=("$shown")
  [[ $n != 記録できない ]] || report+=("- ${name#*/}: 記録できなかった")
}
# 問題がなかったリポジトリの、親が書いた 🔧（子のセッションの形跡の問題は除く）を戻す
repo_ok() {
  local prev
  prev=$(repo_record "$1")
  [[ $prev == 🔧* && $prev != "🔧 delegate:"* ]] || return 0
  record_repo "$1" "– 問題なし" >/dev/null
}
# 子のセッションが動いた形跡がなく、まだ起動し直さない間か
delegate_waiting() {
  local f
  f=$STATE/repos/$(repo_key "$1")/last-result
  [[ $(repo_record "$1") == "🔧 delegate:"* ]] || return 1
  (($(date +%s) - $(perl -e 'print +(stat $ARGV[0])[9]' "$f") < DELEGATE_RETRY))
}
# 子のセッションの前回の結果（リポジトリの .git の last-result）
child_result() { cat "$(state_dir_path "$1" 2>/dev/null)/last-result" 2>/dev/null || true; }
lock_of() { (cd "$1" && bash "$DIR/lock.sh" status 2>&1) || echo "ロック: 確かめられない"; }

[[ -z $FORCED ]] || { verdict=end result=$FORCED parent_line=$FORCED; }
if [[ -z $verdict && -z $running ]]; then
  verdict=end result="– 同じ親ディレクトリの別の実行が動いているので何もしない"
fi

# --- gh のログイン（全体で 1 回） ---
if [[ -z $verdict ]] && ! gh auth status >/dev/null 2>&1; then
  verdict=end result="🔧 gh: gh が未ログイン（\`gh auth login\` を実行する）" parent_line=$result
fi

# --- 対象のリポジトリ ---
paths=() names=()
if [[ -z $verdict ]]; then
  rows=$(bash "$DIR/repos.sh") || { verdict=end result="🔧 repos: 配下のリポジトリを調べられない" parent_line=$result; rows=; }
  while IFS=$'\t' read -r kind a b; do
    case $kind in
      repo) paths+=("$a") names+=("$b") ;;
      skip) report+=("- 対象外: $a（$b）") ;;
      dup) repo_problem "$a" "🔧 repos: checkout が複数ある（$(tr ',' '\n' <<<"$b" | P="$PARENT/" awk '{ s = (index($0, ENVIRON["P"]) == 1 ? substr($0, length(ENVIRON["P"]) + 1) : $0); printf "%s%s", (NR > 1 ? "、" : ""), s }')）" ;;
    esac
  done <<<"$rows"
  if [[ -z $verdict ]] && ((${#paths[@]} == 0)) && ((${#extra[@]} == 0)); then
    verdict=end result="🔧 repos: 対象のリポジトリがない（配下に GitHub のリポジトリの checkout がない）" parent_line=$result
  fi
fi

# --- 前の回に時間内に調べきれなかったリポジトリから調べる ---
if [[ -z $verdict && -f $STATE/cursor ]] && ((${#paths[@]} > 1)); then
  cur=$(cat "$STATE/cursor") k=
  for i in "${!paths[@]}"; do
    if [[ ${names[$i]} == "$cur" ]]; then k=$i; break; fi
  done
  if [[ -n $k ]]; then
    rp=("${paths[@]:$k}" "${paths[@]:0:$k}") rn=("${names[@]:$k}" "${names[@]:0:$k}")
    paths=("${rp[@]}") names=("${rn[@]}")
  fi
fi

# --- 前回起動した子のセッションが動いた形跡 ---
if [[ -z $verdict && -f $STATE/delegated ]]; then
  IFS=$'\t' read -r d_time d_name d_path <"$STATE/delegated" || true
  d_lock=$(lock_of "$d_path")
  if [[ $d_lock != "ロック: 使用中"* ]]; then
    d_rec="$(state_dir_path "$d_path" 2>/dev/null)/last-result"
    if [[ -f $d_rec ]] && (($(perl -e 'print +(stat $ARGV[0])[9]' "$d_rec") >= ${d_time:-0})); then
      [[ $(repo_record "$d_name") != "🔧 delegate:"* ]] || record_repo "$d_name" "– 子のセッションが動いた" >/dev/null
      rm -f "$STATE/delegated"
    elif (($(date +%s) - ${d_time:-0} < START_GRACE)); then
      # 起動した直後（続けて実行したときなど）は、子のセッションがまだロックを取っていないことがある。もう 1 つ起動しない
      verdict=end result="– 前回起動した子のセッションが始まるのを待っている（${d_name#*/}）"
    else
      repo_problem "$d_name" "🔧 delegate: 子のセッションが動いた形跡がない（$(date -r "${d_time:-0}" '+%m/%d %H:%M') に起動）"
      rm -f "$STATE/delegated"
    fi
  fi
fi

# --- ロック（読むだけ）。どれかが使用中なら、新しく起動しない ---
stale_idx=
if [[ -z $verdict ]]; then
  for i in "${!paths[@]}"; do
    l=$(lock_of "${paths[$i]}")
    case $l in
      "ロック: 使用中"*)
        report+=("- ${names[$i]#*/}: $l")
        verdict=end result="– 別の実行が動いているので何もしない（${names[$i]#*/}）"
        break
        ;;
      "ロック: 古い"*)
        report+=("- ${names[$i]#*/}: $l")
        # 子のセッションが動いた形跡がなかったリポジトリは、間隔をあけるまで引き継がない（ほかのリポジトリを調べる）
        if delegate_waiting "${names[$i]}"; then
          report+=("- ${names[$i]#*/}: 子のセッションが動いた形跡がないので、しばらく起動しない")
        elif [[ -z $stale_idx ]]; then
          stale_idx=$i
        fi
        ;;
      "ロック: なし"*) ;;
      *) report+=("- ${names[$i]#*/}: $l") ;;
    esac
  done
fi

# --- 各リポジトリを並列に調べる（古いロックがあれば、調べずにそのリポジトリを引き継ぐ） ---
chosen= chosen_issue=
if [[ -z $verdict && -n $stale_idx ]]; then
  chosen=$stale_idx
elif [[ -z $verdict ]]; then
  start=$(date +%s)
  i=0
  while ((i < ${#paths[@]})); do
    remaining=$((PHASE_LIMIT - ($(date +%s) - start)))
    if ((remaining < 10)); then
      for ((j = i; j < ${#paths[@]}; j++)); do printf 'unchecked\nnot-attempted\n' >"$tmp/$j"; done
      break
    fi
    lim=$((remaining < CHECK_LIMIT ? remaining : CHECK_LIMIT))
    pids=()
    for ((j = i; j < i + JOBS && j < ${#paths[@]}; j++)); do
      (
        if with_limit "$lim" bash "$DIR/parent-precheck.sh" --check-one "${paths[$j]}" "${names[$j]}" ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"} >"$tmp/$j.part" 2>/dev/null; then
          mv "$tmp/$j.part" "$tmp/$j"
        else
          rc=$?
          if ((rc == 124 && lim < CHECK_LIMIT)); then
            # 全体の残り時間で打ち切った（リポジトリごとの上限より短かった）ものは、調べ始めなかったものと同じく次の回に先に調べる
            printf 'unchecked\nnot-attempted\n' >"$tmp/$j"
          elif ((rc == 124)); then printf 'unchecked\n' >"$tmp/$j"; else { cat "$tmp/$j.part"; printf 'problem\t🔧 precheck: 確かめる途中で失敗した（終了コード %s）\n' "$rc"; } >"$tmp/$j"; fi
        fi
      ) &
      pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    i=$j
  done

  # 改名前の URL の clone など、GitHub で同じリポジトリになる checkout を先に求める（その checkout は対象から外す）
  nwos=
  for i in "${!paths[@]}"; do
    nwo=$(awk -F'\t' '$1 == "nwo" { print $2 }' "$tmp/$i" 2>/dev/null || true)
    [[ -z $nwo ]] || nwos="$nwos$nwo$T$i"$'\n'
  done
  dups=$(awk -F'\t' 'NF == 2 { c[$1]++ } END { for (k in c) if (c[k] > 1) print k }' <<<"$nwos")
  dup_idx=" "
  if [[ -n $dups ]]; then
    while IFS= read -r d; do
      [[ -n $d ]] || continue
      repo_problem "$d" "🔧 repos: GitHub で同じリポジトリになる checkout が複数ある"
      dup_idx="$dup_idx$(awk -F'\t' -v k="$d" '$1 == k { printf "%s ", $2 }' <<<"$nwos")"
    done <<<"$dups"
  fi

  # 分類をまとめる
  targets=() checked=0 nolabel=0 unchecked_first=
  for i in "${!paths[@]}"; do
    name=${names[$i]} short=${names[$i]#*/}
    out=$(cat "$tmp/$i" 2>/dev/null || printf 'unchecked\n')
    while IFS=$'\t' read -r kind a b; do
      case $kind in
        info) report+=("- $short: $a") ;;
        skip) report+=("- 対象外: $short（$a）") ;;
      esac
    done <<<"$out"
    if grep -q "^skip$T" <<<"$out"; then continue; fi
    [[ $dup_idx != *" $i "* ]] || continue
    if grep -qx unchecked <<<"$out"; then
      repo_problem "$name" "🔧 precheck: 時間内に確かめられなかった"
      # 次の回は、この回に調べ始めなかった・全体の残り時間で打ち切ったリポジトリから調べる
      # （リポジトリごとの上限で時間切れになったリポジトリが、毎回先頭で時間を使わないように）
      grep -qx not-attempted <<<"$out" && [[ -z $unchecked_first ]] && unchecked_first=$name
      continue
    fi
    checked=$((checked + 1))
    problem=$(awk -F'\t' '$1 == "problem" { print $2; exit }' <<<"$out")
    if [[ -n $problem ]]; then
      repo_problem "$name" "$problem"
      continue
    fi
    repo_ok "$name"
    if grep -qx no-label <<<"$out"; then
      nolabel=$((nolabel + 1))
    elif row=$(grep "^target$T" <<<"$out"); then
      if delegate_waiting "$name"; then
        report+=("- $short: 子のセッションが動いた形跡がないので、しばらく起動しない")
        continue
      fi
      # 並べ替えの鍵: 子のセッションが 🔧 で終えた・形跡がなかったリポジトリは後ろ（1）、作成時刻、添字
      back=0
      [[ $(child_result "${paths[$i]}") != 🔧* && $(repo_record "$name") != "🔧 delegate:"* ]] || back=1
      targets+=("$back$T$(cut -f3 <<<"$row")$T$i$T$(cut -f2 <<<"$row")")
    fi
  done
  # 調べきれなかったリポジトリがあれば、次の回にそこから調べる
  if [[ -n $unchecked_first ]]; then printf '%s\n' "$unchecked_first" >"$STATE/cursor"; else rm -f "$STATE/cursor"; fi
  if ((checked > 0 && nolabel == checked)); then
    parent_line="🔧 find: どのリポジトリにもラベル \`$LABEL\` がない"
  fi
  if ((${#targets[@]} > 0)); then
    best=$(printf '%s\n' "${targets[@]}" | sort -t$'\t' -k1,1n -k2,2 -k3,3n | head -1)
    chosen=$(cut -f3 <<<"$best") chosen_issue=$(cut -f4 <<<"$best")
  fi
fi

# --- Auto-fix の PR の一覧（pr-*.autofix の記録があるリポジトリだけ） ---
af=()
for i in "${!paths[@]}"; do
  ls "$(state_dir_path "${paths[$i]}" 2>/dev/null)"/pr-*.autofix >/dev/null 2>&1 && af+=("$i")
done
if ((${#af[@]} > 0)); then
  for i in "${af[@]}"; do
    (cd "${paths[$i]}" && with_limit "$LIST_LIMIT" bash "$DIR/pr-feedback.sh" --list >"$tmp/af$i" 2>/dev/null || echo "- Auto-fix の PR: 確かめきれなかった" >>"$tmp/af$i") &
  done
  wait || true
  for i in "${af[@]}"; do
    while IFS= read -r line; do
      [[ $line == "- "* ]] && report+=("- ${names[$i]#*/}: Auto-fix ${line#- }")
    done <"$tmp/af$i"
  done
fi

# --- 判定と記録 ---
if [[ -z $verdict && -n $chosen ]]; then
  echo "- 判定: 子のセッションを起動する"
  echo "- リポジトリ: ${paths[$chosen]}"
  echo "- 名前: ${names[$chosen]}"
  [[ -z $chosen_issue ]] || echo "- Issue: #$chosen_issue"
  # 起動の予約。子のセッションがすぐに終えて記録しても、次の回にその記録を「予約のあと」と判定できるように、起動の前に書く
  printf '%s\t%s\t%s\n' "$(date +%s)" "${names[$chosen]}" "${paths[$chosen]}" >"$STATE/delegated"
  # 親の問題（ラベルの有無など）は、起動する回には起きない。親の記録は入口が起動の結果で書く
  for e in ${extra[@]+"${extra[@]}"}; do echo "- 追加の通知: $e"; done
else
  if [[ -z $verdict ]]; then
    verdict=end
    if ((${#extra[@]} > 0)); then
      result=${extra[0]} notify=する
      extra=("${extra[@]:1}")
    elif [[ -n $parent_line ]]; then
      result=$parent_line
    else
      result="– 対象なし"
    fi
  fi
  # 親の記録は、親に固有の結果だけを書く（リポジトリの問題を結果にした回は「親の確認は問題なし」として対象なしを書く）
  if [[ -n $parent_line ]]; then
    n=$(record_parent "$parent_line")
    if [[ $result == "$parent_line" ]]; then
      notify=$n
    elif [[ $n == する ]]; then
      extra+=("$parent_line")
    fi
  else
    if [[ $result == –* ]]; then n=$(record_parent "$result"); else n=$(record_parent "– 対象なし"); fi
    [[ $n != 記録できない ]] || notify=記録できない
    [[ -n $notify ]] || notify=しない
  fi
  if [[ $notify == 記録できない ]]; then
    report+=("- 記録: できなかった")
    result="🔧 record: 結果を記録できなかった（$result）" notify=する
  fi
  echo "- 判定: 終える"
  echo "- 結果: $result"
  echo "- 通知: ${notify:-しない}"
  for e in ${extra[@]+"${extra[@]}"}; do echo "- 追加の通知: $e"; done
fi
echo "## 報告"
((${#report[@]} == 0)) || printf '%s\n' "${report[@]}"
