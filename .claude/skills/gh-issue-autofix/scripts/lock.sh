#!/usr/bin/env bash
# 同じ checkout で、定期実行と手動の実行が重ならないようにする（開発 DB・依存フォルダを共有するため）。
#
# 使い方: lock.sh acquire          # 取れたらトークンを出す。取れなければ終了コード 2
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
  acquire)
    (($# == 1)) || die "使い方: lock.sh acquire"
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
  *) die "使い方: lock.sh acquire | refresh <トークン> | release <トークン>" ;;
esac
