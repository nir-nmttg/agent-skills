#!/usr/bin/env bash
# 定期実行の入口で、全部の手順（references/procedure.md）を読む前に、対象があるかだけを確かめる（読むだけ）。
# 対象がない回は、ここで記録まで済ませて終えられるようにし、長い手順を読み込まずに済ませる。
#
# 使い方: precheck.sh [--label <ラベル>] [--result <結果の 1 行目>]
#   --result: 入口ですでに終えると決めた結果（権限モードの問題など）。その結果を記録し、報告だけを作る。
#   出力（固定の形）:
#     - 判定: 終える | 手順に進む
#     - 結果: <結果の 1 行目>      （終えるとき。record-result.sh で記録済み）
#     - 通知: する | しない        （終えるとき）
#     ## 報告
#     - ロック・着手中か止めた Issue の番号・Auto-fix をオンにした PR のうち対応が要りそうなもの
#   「手順に進む」のは、対象の Issue があるとき、前の実行のロックが古いとき（手順の lock.sh acquire で引き継ぐ）、
#   Issue の検索が時間内に終わらないとき（手順の find-issue.sh には時間の上限がない）。
#   ほかの実行がロックを持っているとき・対象がないとき・Issue を探せないとき・メインの checkout に未コミットの変更があるときは「終える」。
#   Issue・ブランチ・ロックは変えない（「終える」ときに結果を記録するだけ）。
# 終了コード: 0 = 判定を出した、1 = エラー（入口は手順に進む）
set -euo pipefail
DIR=$(cd -P "$(dirname "$0")" && pwd)
source "$DIR/lib.sh"

LIST_LIMIT=240   # pr-feedback.sh --list にかける時間の上限（秒）
FIND_LIMIT=240   # find-issue.sh --check にかける時間の上限（秒）

LABEL_ARGS=() FORCED=
while (($#)); do
  case $1 in
    --result)
      [[ -n ${2:-} ]] || die "--result に結果の 1 行目を指定してください。"
      FORCED=$2
      shift 2
      ;;
    --label)
      [[ -n ${2:-} ]] || die "--label にラベル名を指定してください。"
      LABEL_ARGS=(--label "$2")
      shift 2
      ;;
    *) die "不明な引数: $1" ;;
  esac
done
git rev-parse --show-toplevel >/dev/null 2>&1 || die "git リポジトリの中で実行してください。"

# 時間の上限を付けて実行する（macOS に timeout はないので perl の alarm。子プロセスごと止める）
with_limit() {
  local sec=$1
  shift
  perl -e '
    my $sec = shift;
    my $pid = fork // die "fork: $!";
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or die "exec: $!" }
    local $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; exit 124 };
    alarm $sec;
    waitpid($pid, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$sec" "$@"
}

verdict= result=
report=()
[[ -z $FORCED ]] || { verdict=end; result=$FORCED; }

# 理由を 1 行・200 文字（バイトではなく文字）に切る
one_line() { grep -v '^[[:space:]]*$' | head -1 | perl -CSD -ne 'chomp; print substr($_, 0, 200)' || true; }


# --- ロック（読むだけ） ---
lock=$(bash "$DIR/lock.sh" status 2>&1) || lock="ロック: 確かめられない（${lock%%$'\n'*}）"
report+=("- $lock")
# 手順と同じく、ロックを先に見る（古いロックは手順で引き継ぎ、「途中で止まっていた」を知らせる）
if [[ -z $verdict ]]; then
  case $lock in
    "ロック: 使用中"*) verdict=end result="– 別の実行が動いているので何もしない" ;;
    "ロック: 古い"*) verdict=go ;;
  esac
fi

# --- メインの checkout（読むだけ。手順の sync-base.sh が止まる状態を、対象がない回にも知らせる） ---
if [[ -z $verdict ]]; then
  if [[ $(git rev-parse --show-toplevel) != "$(main_root)" ]]; then
    verdict=end result="🔧 sync: メインの checkout で動いていない（worktree の中で実行している）"
  elif [[ -n $(git status --porcelain) ]]; then
    verdict=end result="🔧 sync: メインの checkout に未コミットの変更がある"
  fi
fi

# --- 対象の Issue ---
if [[ -z $verdict ]]; then
  if out=$(with_limit "$FIND_LIMIT" bash "$DIR/find-issue.sh" --check ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"} 2>&1); then rc=0; else rc=$?; fi
  skipped=$(sed -n 's/^check: skipped //p' <<<"$out")
  waiting=$(sed -n 's/^check: waiting //p' <<<"$out")
  [[ -z $skipped ]] || report+=("- 着手中か、ドラフト PR がある Issue: $skipped")
  [[ -z $waiting ]] || report+=("- 止めた Issue（更新待ち）: $waiting")
  if ((rc == 0)) && grep -qE '^check: target [1-9][0-9]*$' <<<"$out"; then
    verdict=go
  elif ((rc == 0)) && grep -qx 'check: none' <<<"$out"; then
    verdict=end result="– 対象なし"
  elif ((rc == 124)); then
    # 時間切れは対象の有無がわからないので、時間の上限のない手順の find-issue.sh に任せる
    verdict=go
    report+=("- Issue の検索: ${FIND_LIMIT} 秒で終わらなかったので、手順で探し直す")
  else
    # ラベルがない・検索の上限・gh のエラーなど。手順と同じ 🔧 find のコードにして、同じ問題は通知を繰り返さない
    reason=$(grep -v '^check: ' <<<"$out" | one_line)
    verdict=end result="🔧 find: ${reason:-Issue を探せなかった（終了コード $rc）}"
  fi
fi

# --- Auto-fix をオンにした PR（報告に書くだけ。手順に進むときは、手順の「終えるとき」で同じものを出すので飛ばす） ---
if [[ $verdict != go ]]; then
  if list=$(with_limit "$LIST_LIMIT" bash "$DIR/pr-feedback.sh" --list 2>/dev/null); then list_ok=true; else list_ok=false; fi
  if $list_ok && grep -qx -- '- 対応が要りそうな PR: なし' <<<"$list"; then
    report+=("- Auto-fix の PR で対応が要りそうなもの: なし")
  else
    # 途中まで出た一覧は残し、確かめきれなかったことを書き足す
    items=$(grep -E '^- #[0-9]+: ' <<<"$list" || true)
    if [[ -n $items ]]; then
      report+=("- Auto-fix の PR で対応が要りそうなもの$($list_ok || echo "（確かめきれなかった。途中まで）"):")
      while IFS= read -r line; do report+=("  $line"); done <<<"$items"
    else
      report+=("- Auto-fix の PR: 確かめられなかった")
    fi
  fi
fi

if [[ $verdict == go ]]; then
  echo "- 判定: 手順に進む"
else
  notify=
  rec=$(bash "$DIR/record-result.sh" "$result" 2>&1) || rec=
  case $(grep '^通知: ' <<<"$rec" || true) in
    "通知: する"*) notify=する ;;
    "通知: しない"*) notify=しない ;;
  esac
  # 記録できなかったときは、そのことを結果にして通知する（重複の抑止はあきらめる）
  if [[ -z $notify ]]; then
    report+=("- 記録: できなかった（$(one_line <<<"${rec:-record-result.sh が失敗した}")）")
    result="🔧 record: 結果を記録できなかった（$result）"
    notify=する
  fi
  echo "- 判定: 終える"
  echo "- 結果: $result"
  echo "- 通知: $notify"
fi
echo "## 報告"
printf '%s\n' "${report[@]}"
