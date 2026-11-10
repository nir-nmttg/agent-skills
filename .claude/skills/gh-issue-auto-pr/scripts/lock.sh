#!/usr/bin/env bash
# 同じ checkout で、定期実行と手動の実行が重ならないようにする（開発 DB・依存フォルダを共有するため）。
#
# 使い方: lock.sh acquire          # 取れたらトークンを出す。取れなければ終了コード 2
#         lock.sh acquire --wait <分> # 取れるまで 60 秒ごとに取り直す。時間切れ・呼び出し元の終了は終了コード 2
#         lock.sh status            # 読むだけ: 「ロック: なし」「ロック: 使用中（N 分前に更新）」「ロック: 古い（N 分前に更新）」
#         lock.sh refresh <トークン> # 動いていることを記録する（手順の区切りごとに呼ぶ）
#         lock.sh release <トークン> # 自分のロックのときだけ外す
#   3 時間 refresh されていないロックは、止まった実行の残りとみなして引き継ぐ。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

LOCK_MAX_MINUTES=180

git rev-parse --show-toplevel >/dev/null 2>&1 || die "git リポジトリの中で実行してください。"
STATE=$(state_dir)
LOCK=$STATE/lock

# ロックのフォルダを作り、トークンを書く。mkdir は 1 つしか成功しない
take() {
  mkdir "$LOCK" 2>/dev/null || return 1
  local token
  token="$(date +%s)-$$-$RANDOM$RANDOM"
  echo "$token" >"$LOCK/token"
  echo "ロックを取りました。トークン: $token"
}
is_stale() { [[ -n $(find "$1" -maxdepth 0 -mmin +"$LOCK_MAX_MINUTES" 2>/dev/null) ]]; }
busy() { stop "別の実行が動いています。この実行は何もせずに終えます。"; }

case ${1:-} in
  status)
    (($# == 1)) || die "使い方: lock.sh status"
    [[ -d $LOCK ]] || { echo "ロック: なし"; exit 0; }
    minutes=$(perl -e 'my @s = stat($ARGV[0]); print @s ? int((time - $s[9]) / 60) : -1' "$LOCK")
    ((minutes >= 0)) || { echo "ロック: なし"; exit 0; }
    # 引き継ぐかどうかは acquire と同じ is_stale で決める
    if is_stale "$LOCK"; then echo "ロック: 古い（${minutes} 分前に更新）"; else echo "ロック: 使用中（${minutes} 分前に更新）"; fi
    ;;
  acquire)
    if (($# == 3)) && [[ $2 == --wait ]]; then
      # 取れるまで 60 秒ごとに取り直す。呼び出し元が終わったら、取らずにやめる（受け取る者のいないロックを残さない）
      [[ $3 =~ ^[1-9][0-9]*$ ]] || die "--wait には待つ分数を指定してください: $3"
      owner=$PPID
      deadline=$(($(date +%s) + $3 * 60))
      while :; do
        kill -0 "$owner" 2>/dev/null || stop "呼び出し元が終わったので、ロックを待つのをやめます。"
        if out=$(bash "$0" acquire 2>&1); then
          # 取った直後に呼び出し元が終わっていたら、受け取る者がいないので外す
          if ! kill -0 "$owner" 2>/dev/null; then
            token=$(sed -n 's/^ロックを取りました。トークン: //p' <<<"$out")
            [[ -z $token ]] || bash "$0" release "$token" >/dev/null
            stop "呼び出し元が終わったので、取ったロックを外しました。"
          fi
          echo "$out"
          exit 0
        else
          rc=$?
        fi
        ((rc == 2)) || die "$out"
        (($(date +%s) < deadline)) || stop "別の実行が動いていて、$3 分待ってもロックを取れませんでした。"
        sleep 60
      done
    fi
    (($# == 1)) || die "使い方: lock.sh acquire [--wait <分>]"
    take && exit 0
    seen=$(cat "$LOCK/token" 2>/dev/null || true)
    is_stale "$LOCK" || busy
    # 古いロックを別名に移す。移したものが、見たときと同じ古いロックかを確かめてから消す
    stale="$STATE/lock.stale.$$"
    mv "$LOCK" "$stale" 2>/dev/null || busy
    if [[ $(cat "$stale/token" 2>/dev/null || true) != "$seen" ]] || ! is_stale "$stale"; then
      # その間に別の実行が取り直した新しいロックだったので、戻して譲る（すでに別のロックがあれば入れ子にしない）
      [[ -e $LOCK ]] || mv "$stale" "$LOCK" 2>/dev/null || true
      busy
    fi
    rm -rf "$stale"
    take || busy
    echo "注意: 前の実行のロックが ${LOCK_MAX_MINUTES} 分以上更新されていなかったので引き継ぎました。前の実行は途中で止まった可能性があります。"
    ;;
  refresh)
    (($# == 2)) || die "使い方: lock.sh refresh <トークン>"
    [[ $(cat "$LOCK/token" 2>/dev/null || true) == "$2" ]] || stop "ロックが別の実行に引き継がれています。この実行は終えてください。"
    touch "$LOCK"
    ;;
  release)
    (($# == 2)) || die "使い方: lock.sh release <トークン>"
    # 別名に移してからトークンを確かめる（確かめてから消すまでの間に引き継がれても、新しいロックを消さない）
    moved="$STATE/lock.release.$$"
    if mv "$LOCK" "$moved" 2>/dev/null; then
      if [[ $(cat "$moved/token" 2>/dev/null || true) == "$2" ]]; then
        rm -rf "$moved"
        echo "ロックを外しました。"
        exit 0
      fi
      [[ -e $LOCK ]] || mv "$moved" "$LOCK" 2>/dev/null || true
    fi
    echo "自分のロックではないので外しません（引き継がれたか、すでに外れています）。"
    ;;
  *) die "使い方: lock.sh status | acquire [--wait <分>] | refresh <トークン> | release <トークン>" ;;
esac
