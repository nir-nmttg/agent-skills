#!/usr/bin/env bash
# security-audit-verifier の PreToolUse hook。Verifier が実行フォルダの外を読む・書く事故と、GitHub への書き込みを止める。
# 悪意のある回避（sh -c で包むなど）は想定しない。監視はメインのセッションの権限（auto モードの分類器など）に任せる。
#
# 標準入力に hook の JSON を受け取り、許可なら終了コード 0、止めるなら理由を標準エラーに出して終了コード 2 で終わる。
# 実行フォルダとして認めるのは、置き場所（このリポジトリ直下の artifacts/security-audit-verify-items）のうち、
# prepare.sh で用意した（repo と worktree がある）フォルダだけ。
# - Read / Grep / Glob: パスが実行フォルダの中でなければ止める（Grep / Glob の path の省略も止める）
# - Write: 実体のパスが実行フォルダの items/ の中でなければ止める
# - Bash: 先頭が「cd <実行フォルダの中> &&」でなければ止める。gh、リポジトリの状態を変える git、依存を入れるコマンドも止める
# 判定できないときも止める（hook は 2 以外の終了コードだと素通りになるため）。
set -uo pipefail

deny() { printf '%s\n' "$*" >&2; exit 2; }

source "$(dirname "$0")/lib.sh" || deny "security-audit-verify-items の guard.sh: lib.sh を読み込めないため止めました"
command -v jq >/dev/null || deny "security-audit-verify-items の guard.sh: jq がないため止めました（brew install jq）"
command -v perl >/dev/null || deny "security-audit-verify-items の guard.sh: perl がないため止めました"

input=$(cat)
field() { jq -r "$1 // \"\"" <<<"$input" 2>/dev/null || deny "security-audit-verify-items の guard.sh: hook の入力を読めないため止めました"; }
tool=$(field .tool_name) || exit 2
cwd=$(field .cwd) || exit 2

root=$(runs_root) || deny "security-audit-verify-items の guard.sh: 実行フォルダの置き場所を決められないため止めました"
root_real=$(cd -P "$root" 2>/dev/null && pwd) || deny "実行フォルダの置き場所 $root がありません。prepare.sh で用意した実行フォルダで作業してください"

# real <path>  実体のパスを出力する（相対パスは hook の cwd から）。.. の要素を含むパスは判定を誤りうるので止める
real() {
  [[ /$1/ == */../* ]] && deny "パスに .. を含めないでください: $1"
  [[ $1 == /* ]] && real_path "$1" || (cd "${cwd:-$PWD}" 2>/dev/null && real_path "$1")
}

# run_of <実体のパス>  そのパスを含む、用意済みの実行フォルダを出力する
run_of() {
  local p=$1 run
  [[ $p == "$root_real"/* ]] || return 1
  run=${p#"$root_real"/}
  run=${run%%/*}
  [[ -n $run && -f $root_real/$run/repo && -d $root_real/$run/worktree ]] || return 1
  printf '%s\n' "$root_real/$run"
}

hint="作業場所は依頼で渡された実行フォルダです"

case $tool in
  Read)
    path=$(field .tool_input.file_path) || exit 2
    [[ -n $path ]] || deny "file_path がありません"
    [[ /$path/ == */../* ]] && deny "パスに .. を含めないでください: $path"
    p=$(real "$path") || deny "パスを解決できないため止めました: $path"
    run_of "$p" >/dev/null || deny "実行フォルダの外は読めません: ${path}。${hint}"
    ;;
  Grep | Glob)
    path=$(field .tool_input.path) || exit 2
    [[ -n $path ]] || deny "path を指定してください（省略するとメインの作業フォルダが対象になります）。${hint}"
    p=$(real "$path") || deny "パスを解決できないため止めました: $path"
    run_of "$p" >/dev/null || deny "実行フォルダの外は検索できません: ${path}。${hint}"
    ;;
  Write)
    path=$(field .tool_input.file_path) || exit 2
    [[ -n $path ]] || deny "file_path がありません"
    p=$(real "$path") || deny "パスを解決できないため止めました: $path"
    run=$(run_of "$p") || deny "実行フォルダの外には書けません: ${path}。${hint}"
    [[ $p == "$run/items/"* ]] || deny "書けるのは実行フォルダの items/ の中だけです: $path"
    ;;
  Bash)
    cmd=$(field .tool_input.command) || exit 2
    cd_re='^[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+)[[:space:]]*&&'
    [[ $cmd =~ $cd_re ]] ||
      deny "Bash は毎回メインの作業フォルダで始まります（cd は引き継がれません）。先頭に「cd <実行フォルダの中> &&」を付けてください。${hint}"
    dir=${BASH_REMATCH[1]}
    dir=${dir#[\"\']}
    dir=${dir%[\"\']}
    p=$(real "$dir") || deny "cd 先を解決できないため止めました: $dir"
    run_of "$p" >/dev/null || deny "cd 先が実行フォルダの外です: ${dir}。${hint}"
    sep='(^|[;&|(`[:space:]/])'
    grep -Eq "${sep}gh([[:space:]]|$)" <<<"$cmd" &&
      deny "gh は使えません。Issue のデータは実行フォルダの issues/ にあります"
    git_re="${sep}git([[:space:]][^;&|]*)?[[:space:]](commit|push|pull|fetch|remote|submodule|notes|am|stash|checkout|switch|reset|rebase|merge|cherry-pick|revert|tag|worktree|clean|branch|update-ref|config|gc|prune|restore|apply)([[:space:]]|$)"
    grep -Eq "$git_re" <<<"$cmd" &&
      deny "リポジトリの状態を変える git コマンドは使えません。必要なら報告に書いてください"
    opts='([[:space:]]+-[^[:space:]]+)*'
    pkg_re="${sep}((npm|pnpm)${opts}[[:space:]]+(install|i|ci|add|update|up|upgrade|uninstall|remove|rm|un)|yarn${opts}[[:space:]]+(add|install|remove|upgrade|up)|bundle${opts}[[:space:]]+(install|update|add)|gem${opts}[[:space:]]+install|pip3?${opts}[[:space:]]+(install|uninstall)|python3?${opts}[[:space:]]+-m[[:space:]]+pip${opts}[[:space:]]+(install|uninstall)|uv${opts}[[:space:]]+(add|remove|sync|lock|pip[[:space:]]+(install|uninstall|sync))|poetry${opts}[[:space:]]+(add|remove|install|update|lock|sync)|composer${opts}[[:space:]]+(install|require|update|remove)|cargo${opts}[[:space:]]+(add|install|update|remove)|go${opts}[[:space:]]+get|brew${opts}[[:space:]]+(install|upgrade))([[:space:]]|$)"
    grep -Eq "$pkg_re" <<<"$cmd" &&
      deny "依存パッケージのインストール・更新はできません。必要なら報告に書いてください"
    ;;
  *)
    deny "このツールは使えません: $tool"
    ;;
esac
exit 0
