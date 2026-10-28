#!/usr/bin/env bash
# ほかの実行フォルダのテストが終わるのを待ってから、コマンドを実行する（並行する Haiku どうしが DB を取り合わないように）。
#
# 使い方: locked.sh <コマンド> [引数...]
#   シェルの機能（パイプ、&& など）を使うときは locked.sh bash -c '...' のように渡す
#
# ロックは実行フォルダの置き場所（このリポジトリ直下の artifacts/haiku-impl）の .test-lock。
# 待つのは HAIKU_IMPL_LOCK_WAIT 秒まで（既定 300 秒）で、超えたら終了コード 75 で終わる。
# macOS に flock コマンドがないため perl の flock を使う。ロックのファイルをコマンドに引き継ぐので、
# ロックはコマンドが終わるまで残り、プロセスが終われば自動で外れる。
set -euo pipefail

(($#)) || { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
source "$(dirname "$0")/lib.sh"

root=$(runs_root) || exit 1
mkdir -p "$root"
wait=${HAIKU_IMPL_LOCK_WAIT:-300}
[[ $wait =~ ^[0-9]+$ ]] || { echo "エラー: HAIKU_IMPL_LOCK_WAIT は秒数で指定してください" >&2; exit 1; }

exec perl -MFcntl=:flock -e '
  my ($lock, $wait) = (shift, shift);
  $^F = 255; # ロックのファイルを exec の先に引き継ぐ
  open(my $fh, ">>", $lock) or die "ロックを開けません: $!\n";
  my $waited = 0;
  until (flock($fh, LOCK_EX | LOCK_NB)) {
    print STDERR "テストの順番待ち: ほかの実行フォルダのテストが終わるのを待っています（最大 ${wait} 秒）\n" if $waited == 0;
    if ($waited >= $wait) {
      print STDERR "ほかの実行フォルダのテストが ${wait} 秒たっても終わらないため、待つのをやめました。しばらくしてから再実行してください\n";
      exit 75;
    }
    sleep 1;
    $waited++;
  }
  exec @ARGV or die "実行できません: $!\n";
' "$root/.test-lock" "$wait" "$@"
