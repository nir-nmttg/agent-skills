#!/usr/bin/env bash
# 親ディレクトリのモードの入口の確認（precheck.sh が、親ディレクトリで実行されたときに呼ぶ）。
# 配下のリポジトリ（repos.sh の REPO_DEPTH 階層まで）を読むだけで調べ、このセッションが作業するリポジトリと、
# Issue の手順か PR の対応かを 1 つ決めるか、終えると決める。
# Issue・ブランチ・リポジトリのファイルは変えない（記録は lib.sh の parent_state_dir に書く）。
#
# 使い方: parent-precheck.sh [--label <ラベル>] [--result <結果の 1 行目>]
#         parent-precheck.sh --check-one <パス> <owner/name> [--label <ラベル>]   # 1 つのリポジトリを調べる（内部用）
#   出力（固定の形）:
#     - モード: 親ディレクトリ                 （必ず最初に出す）
#     - 判定: 手順に進む | PR に対応する | 終える
#     - リポジトリ: <メインの checkout のパス>   （手順に進む・PR に対応するとき）
#     - 名前: <owner/name>                     （同上）
#     - Issue: #<番号>                         （手順に進むとき。古いロックの引き継ぎのときは出さない）
#     - PR: #<番号>                            （PR に対応するとき。定期実行の記録がある PR）
#     - 結果: <結果の 1 行目>                  （終えるとき。記録済み）
#     - 通知: する | しない                    （終えるとき）
#     - 追加の通知: <1 行>                     （ほかにも通知が要る問題があるとき。記録済みなので、入口が必ず送る）
#     ## 報告
#   「全体で 1 件」: どれかのリポジトリのロックが使用中なら、何もしない（手動の実行・Auto-fix の対応が動いている。
#   配下のリポジトリは DB などのコンテナを共有することがあるので、作業を並行させない）。
#   選ぶ順: 古いロックの引き継ぎ → 定期実行の PR（前回の結果が 🔧・⏸️ のもの、前に選んだのに記録が進まなかったものを除く）
#   → Issue（前回の手順の結果が 🔧 のリポジトリは後ろ）→ 除いた定期実行の PR。
#   環境変数 GH_ISSUE_AUTO_PR_AUTOFIX が 0 / off なら、PR は選ばない（報告にだけ書く）。
#   リポジトリの問題は、親の記録（record-result.sh --parent --repo）にリポジトリごとに書く。リポジトリの .git の記録は手順だけが書く。
#   時間内に調べきれなかったリポジトリは、次の回に先頭から調べる（親の記録の cursor）。
#   選んだら予約（親の記録の reserved）を書く。手順がリポジトリのロックを取るまでの間に別の実行が始まっても、
#   RESERVE_GRACE のあいだ、そのリポジトリの記録（.git の last-result*）が予約のあとに更新されていなければ何もしない。
# 終了コード: 0 = 判定を出した、1 = エラー（入口は手順に進まず 🔧 precheck で終える）
set -euo pipefail
echo "- モード: 親ディレクトリ"
DIR=$(cd -P "$(dirname "$0")" && pwd)
source "$DIR/lib.sh"

CHECK_LIMIT=240   # リポジトリごとの確認の上限（秒）
PHASE_LIMIT=300   # 全部のリポジトリの確認にかける上限（秒）
LIST_LIMIT=150    # 自動の対応の記録がある PR の一覧にかける上限（秒）
JOBS=4            # 同時に調べるリポジトリの数
RESERVE_GRACE=900 # 作業するものを選んでから、そのリポジトリの手順が始まった形跡を待つ時間（秒）
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
  # 定期実行の記録がある PR があれば、未コミットの変更は PR の対応も止めるので問題にする
  sched=false
  for f in "$(state_dir_path 2>/dev/null)"/pr-*.autofix; do
    if [[ -f $f && $(cat "$f" 2>/dev/null) == scheduled ]]; then sched=true; break; fi
  done
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
    if [[ -n $dirty ]] && $sched; then
      printf 'problem\t🔧 sync: メインの checkout に未コミットの変更がある\n'
    elif [[ -n $dirty ]]; then
      printf 'info\tメインの checkout に未コミットの変更がある\n'
    fi
  elif ((rc == 0)) && grep -qx 'check: no-label' <<<"$out"; then
    echo no-label
    if [[ -n $dirty ]] && $sched; then printf 'problem\t🔧 sync: メインの checkout に未コミットの変更がある\n'; fi
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
# 同じ親ディレクトリの確認どうしが重ならないようにする（手動の実行と定期実行が同時に調べて、同じものを選ばないように）。
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
# 問題がなかったリポジトリの、親が書いた 🔧 を戻す（前の版の 🔧 delegate も含む）
repo_ok() {
  [[ $(repo_record "$1") == 🔧* ]] || return 0
  record_repo "$1" "– 問題なし" >/dev/null
}
# リポジトリの記録のフォルダ（.git の gh-issue-auto-pr）
repo_state() { state_dir_path "$1" 2>/dev/null; }
# 前回の手順の結果（リポジトリの .git の last-result）
prev_result() { cat "$(repo_state "$1")/last-result" 2>/dev/null || true; }
mtime() { perl -e 'my @s = stat $ARGV[0]; print @s ? $s[9] : 0' "$1"; }
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

# 前の版（子のセッションに任せていた版）の起動の予約は使わない
rm -f "$STATE/delegated"

# --- 前の実行の予約（選んでから、手順がリポジトリのロックを取るまでの間を守る） ---
if [[ -z $verdict && -f $STATE/reserved ]]; then
  IFS=$'\t' read -r r_name r_path <"$STATE/reserved" || true
  if (($(date +%s) - $(mtime "$STATE/reserved") < RESERVE_GRACE)) &&
    [[ -z $(find "$(repo_state "$r_path")" -maxdepth 1 -name 'last-result*' -newer "$STATE/reserved" 2>/dev/null | head -1) ]]; then
    verdict=end result="– 前の実行が始まるのを待っている（${r_name#*/}）"
  else
    rm -f "$STATE/reserved"
  fi
fi

# --- ロック（読むだけ）。どれかが使用中なら、何もしない ---
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
        [[ -n $stale_idx ]] || stale_idx=$i
        ;;
      "ロック: なし"*) ;;
      *) report+=("- ${names[$i]#*/}: $l") ;;
    esac
  done
fi

targets=() ok_idx=" "   # Issue の候補・問題のなかったリポジトリの添字（調べなかった回は空）
# --- 各リポジトリを並列に調べる（古いロックがあれば、調べずにそのリポジトリを引き継ぐ） ---
if [[ -z $verdict && -z $stale_idx ]]; then
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
  checked=0 nolabel=0 unchecked_first=
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
    ok_idx="$ok_idx$i "
    if grep -qx no-label <<<"$out"; then
      nolabel=$((nolabel + 1))
    elif row=$(grep "^target$T" <<<"$out"); then
      # 並べ替えの鍵: 前回の手順の結果が 🔧 のリポジトリは後ろ（1）、作成時刻、添字
      back=0
      [[ $(prev_result "${paths[$i]}") != 🔧* ]] || back=1
      targets+=("$back$T$(cut -f3 <<<"$row")$T$i$T$(cut -f2 <<<"$row")")
    fi
  done
  # 調べきれなかったリポジトリがあれば、次の回にそこから調べる
  if [[ -n $unchecked_first ]]; then printf '%s\n' "$unchecked_first" >"$STATE/cursor"; else rm -f "$STATE/cursor"; fi
  if ((checked > 0 && nolabel == checked)); then
    parent_line="🔧 find: どのリポジトリにもラベル \`$LABEL\` がない"
  fi
fi

# --- 自動の対応の記録がある PR の一覧（pr-*.autofix の記録があるリポジトリだけ。報告と、定期実行の PR の候補） ---
af=()
for i in "${!paths[@]}"; do
  ls "$(repo_state "${paths[$i]}")"/pr-*.autofix >/dev/null 2>&1 && af+=("$i")
done
pr_front=() pr_back=()
case ${GH_ISSUE_AUTO_PR_AUTOFIX:-} in 0 | off) pr_off=true ;; *) pr_off=false ;; esac
if ((${#af[@]} > 0)); then
  for i in "${af[@]}"; do
    (cd "${paths[$i]}" && with_limit "$LIST_LIMIT" bash "$DIR/pr-feedback.sh" --list >"$tmp/af$i" 2>/dev/null || echo "- 自動の対応の PR: 確かめきれなかった" >>"$tmp/af$i") &
  done
  wait || true
  mkdir -p "$STATE/chosen"
  rm -f "$STATE/chosen-pr"   # 前の版の、最後に選んだ PR だけの記録
  for i in "${af[@]}"; do
    while IFS= read -r line; do
      [[ $line == "- "* ]] || continue
      report+=("- ${names[$i]#*/}: 自動の対応 ${line#- }")
      # 定期実行の PR の候補: あり・上限・対象外（取得不完全などは報告だけ）
      [[ $line =~ ^-\ \#([1-9][0-9]*):\ (あり|上限|対象外).*（定期実行）$ ]] || continue
      n=${BASH_REMATCH[1]}
      $pr_off && continue
      # 問題のない（調べきれて、未コミットの変更などがない）リポジトリだけ
      [[ $ok_idx == *" $i "* ]] || continue
      # 前回の結果が 🔧・⏸️ の PR、前に選んだのに記録が進まなかった（選んだ時刻より記録が古い）PR は後ろに回す
      rec=$(repo_state "${paths[$i]}")/last-result-pr-$n
      ch=$STATE/chosen/$(repo_key "${names[$i]}")__$n
      t_rec=$(mtime "$rec") t_ch=$(mtime "$ch")
      back=0
      case $(cat "$rec" 2>/dev/null || true) in 🔧* | ⏸*) back=1 ;; esac
      ((t_rec >= t_ch)) || back=1
      # 後ろに回した PR は、最後に触れた時刻（記録か選んだ時刻の新しいほう）が古いものから選ぶ
      if ((back)); then pr_back+=("$((t_rec > t_ch ? t_rec : t_ch))$T$i$T$n"); else pr_front+=("$i$T$n"); fi
    done <"$tmp/af$i"
  done
  $pr_off && ((${#pr_front[@]} + ${#pr_back[@]} == 0)) && grep -q '（定期実行）' "$tmp"/af* 2>/dev/null &&
    report+=("- 定期実行の PR: 環境変数 GH_ISSUE_AUTO_PR_AUTOFIX で無効にしているので対応しない")
fi

# --- 選ぶ ---
chosen= chosen_issue= chosen_pr=
if [[ -z $verdict && -n $stale_idx ]]; then
  chosen=$stale_idx
elif [[ -z $verdict ]]; then
  if ((${#pr_front[@]} > 0)); then
    chosen=$(cut -f1 <<<"${pr_front[0]}") chosen_pr=$(cut -f2 <<<"${pr_front[0]}")
  elif ((${#targets[@]} > 0)); then
    best=$(printf '%s\n' "${targets[@]}" | sort -t$'\t' -k1,1n -k2,2 -k3,3n | head -1)
    chosen=$(cut -f3 <<<"$best") chosen_issue=$(cut -f4 <<<"$best")
  elif ((${#pr_back[@]} > 0)); then
    # 後ろに回した PR は、前回の結果が古いものから順に（同じ PR ばかり選ばないように）
    best=$(printf '%s\n' "${pr_back[@]}" | sort -t$'\t' -k1,1n -k2,2n -k3,3n | head -1)
    chosen=$(cut -f2 <<<"$best") chosen_pr=$(cut -f3 <<<"$best")
  fi
fi

# --- 判定と記録 ---
if [[ -z $verdict && -n $chosen ]]; then
  short=${names[$chosen]#*/}
  if [[ -n $chosen_pr ]]; then
    echo "- 判定: PR に対応する"
    line="– $short の PR #$chosen_pr に対応した"
    # 次の回から、この PR の記録が進んだか（対応が動いたか）を確かめるために、PR ごとに選んだ時刻を残す
    : >"$STATE/chosen/$(repo_key "${names[$chosen]}")__$chosen_pr"
  else
    echo "- 判定: 手順に進む"
    if [[ -n $chosen_issue ]]; then line="– $short の Issue #$chosen_issue に進んだ"; else line="– $short の前の実行のロックを引き継いだ"; fi
  fi
  echo "- リポジトリ: ${paths[$chosen]}"
  echo "- 名前: ${names[$chosen]}"
  [[ -z $chosen_issue ]] || echo "- Issue: #$chosen_issue"
  [[ -z $chosen_pr ]] || echo "- PR: #$chosen_pr"
  # 選んだことを予約として残す（手順がロックを取るまでの間に、別の実行が別のリポジトリを選ばないように）
  printf '%s\t%s\n' "${names[$chosen]}" "${paths[$chosen]}" >"$STATE/reserved"
  # 親の記録。親の問題（PR を選んだ回の「どこにもラベルがない」など）があればそれを書き、なければ選んだことを書いて
  # 親の 🔧 の重複の抑止を戻す。結果の記録と通知は、手順がリポジトリの記録で行う
  if [[ -n $parent_line ]]; then
    [[ $(record_parent "$parent_line") != する ]] || extra+=("$parent_line")
  else
    record_parent "$line" >/dev/null
  fi
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
