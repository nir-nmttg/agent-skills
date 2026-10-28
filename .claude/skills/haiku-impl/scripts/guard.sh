#!/usr/bin/env bash
# haiku-implementer の PreToolUse hook。Haiku が worktree の外を変えてしまう事故を止める。
# 悪意のある回避（sh -c で包むなど）は想定しない。監視はメインのセッションの権限（auto モードの分類器など）に任せる。
#
# 標準入力に hook の JSON を受け取り、許可なら終了コード 0、止めるなら理由を標準エラーに出して終了コード 2 で終わる。
# 作業場所として認めるのは、実行フォルダの置き場所（このリポジトリ直下の artifacts/haiku-impl）のうち、
# prepare.sh で準備済み（repo と worktree がある）の実行フォルダだけ。
# - Edit / Write: 実体のパスが worktree の中（.git を除く）でなければ止める。リンクした依存フォルダは実体がもとのリポジトリなので止まる
# - Grep / Glob: path が実行フォルダの中でなければ止める（省略するとメインの作業フォルダが対象になるので止める）。
#   読み取りだけなので、リンクした依存フォルダ（実体はもとのリポジトリ）の中も見かけのパスで判定して通す
# - Bash: 先頭が「cd <実行フォルダの中> &&」でなければ止める（サブエージェントの Bash は毎回メインの作業フォルダで始まる）。
#   リポジトリの状態を変える git コマンドと、依存パッケージを入れる・更新するコマンドも止める
# 判定できないときも止める（hook は 2 以外の終了コードだと素通りになるため）。
set -uo pipefail

deny() { printf '%s\n' "$*" >&2; exit 2; }

source "$(dirname "$0")/lib.sh" || deny "haiku-impl の guard.sh: lib.sh を読み込めないため止めました"
command -v jq >/dev/null || deny "haiku-impl の guard.sh: jq がないため止めました（brew install jq）"
command -v perl >/dev/null || deny "haiku-impl の guard.sh: perl がないため止めました"

input=$(cat)
field() { jq -r "$1 // \"\"" <<<"$input" 2>/dev/null || deny "haiku-impl の guard.sh: hook の入力を読めないため止めました"; }
# field はサブシェルで動くので、失敗したらここで止める
tool=$(field .tool_name) || exit 2
cwd=$(field .cwd) || exit 2

root=$(runs_root) || deny "haiku-impl の guard.sh: 実行フォルダの置き場所を決められないため止めました"
root_real=$(cd -P "$root" 2>/dev/null && pwd) || deny "実行フォルダの置き場所 $root がありません。prepare.sh で準備した worktree で作業してください"

# real <path>  実体のパスを出力する（相対パスは hook の cwd から）
real() { [[ $1 == /* ]] && real_path "$1" || (cd "${cwd:-$PWD}" 2>/dev/null && real_path "$1"); }

# run_of <実体のパス>  そのパスを含む、準備済みの実行フォルダを出力する
run_of() {
  local p=$1 run
  [[ $p == "$root_real"/* ]] || return 1
  run=${p#"$root_real"/}
  run=${run%%/*}
  [[ -n $run && -f $root_real/$run/repo && -d $root_real/$run/worktree ]] || return 1
  printf '%s\n' "$root_real/$run"
}

workplace_hint="作業場所は prompt.md の「作業場所（worktree）」です"

case $tool in
  Edit | Write)
    path=$(field .tool_input.file_path) || exit 2
    [[ -n $path ]] || deny "file_path がありません"
    p=$(real "$path") || deny "パスを解決できないため止めました: $path"
    run=$(run_of "$p") || deny "worktree の外のファイルは編集できません: ${path}。${workplace_hint}"
    wt=$run/worktree
    [[ $p == "$wt"/* ]] || deny "worktree の外のファイルは編集できません: ${path}。${workplace_hint}"
    rel=${p#"$wt"/}
    [[ $rel != .git && $rel != .git/* ]] || deny "worktree の .git は編集できません: $path"
    ;;
  Grep | Glob)
    path=$(field .tool_input.path) || exit 2
    [[ -n $path ]] || deny "path を指定してください（省略するとメインの作業フォルダが対象になります）。${workplace_hint}"
    # まず見かけのパスで判定する（読み取りだけなので、リンクした依存フォルダの中も通す）。
    # 重複する / と . の要素を除き、.. の要素がないときだけ使う。だめなら実体のパスで判定する（/tmp と /private/tmp などの別表記）
    abs=$path
    [[ $abs == /* ]] || abs=${cwd:-$PWD}/$abs
    abs=$(sed -E -e 's#/+#/#g' -e ':a' -e 's#/\./#/#' -e 'ta' -e 's#/\.$##' <<<"$abs")
    lexical_ok=""
    if [[ /$abs/ != */../* ]]; then
      for base in "$root_real" "$root"; do
        [[ $abs == "$base"/* ]] || continue
        run_of "$root_real/${abs#"$base"/}" >/dev/null && lexical_ok=1
        break
      done
    fi
    if [[ -z $lexical_ok ]]; then
      p=$(real "$path") || deny "パスを解決できないため止めました: $path"
      run_of "$p" >/dev/null || deny "実行フォルダの外は検索できません: ${path}。${workplace_hint}"
    fi
    ;;
  Bash)
    cmd=$(field .tool_input.command) || exit 2
    cd_re='^[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+)[[:space:]]*&&'
    [[ $cmd =~ $cd_re ]] ||
      deny "Bash は毎回メインの作業フォルダで始まります（cd は引き継がれません）。先頭に「cd <作業場所> &&」を付けてください。${workplace_hint}"
    dir=${BASH_REMATCH[1]}
    dir=${dir#[\"\']}
    dir=${dir%[\"\']}
    p=$(real "$dir") || deny "cd 先を解決できないため止めました: $dir"
    run_of "$p" >/dev/null || deny "cd 先が実行フォルダの外です: ${dir}。${workplace_hint}"
    # コマンド名の前は行頭・区切り・空白・パス（.venv/bin/pip など）。git のオプションの解析は避け、
    # 同じ単純コマンドの中に禁止のサブコマンドが単語として現れたら止める（git log --grep commit なども止まるが、事故防止を優先する）
    sep='(^|[;&|(`[:space:]/])'
    git_re="${sep}git([[:space:]][^;&|]*)?[[:space:]](commit|push|pull|fetch|remote|submodule|notes|am|stash|checkout|switch|reset|rebase|merge|cherry-pick|revert|tag|worktree|clean|branch|update-ref|config|gc|prune)([[:space:]]|$)"
    grep -Eq "$git_re" <<<"$cmd" &&
      deny "リポジトリの状態を変える git コマンドは使えません（worktree は .git をもとのリポジトリと共有しています）。必要なら報告に書いてください"
    opts='([[:space:]]+-[^[:space:]]+)*'
    pkg_re="${sep}((npm|pnpm)${opts}[[:space:]]+(install|i|ci|add|update|up|upgrade|uninstall|remove|rm|un)|yarn${opts}[[:space:]]+(add|install|remove|upgrade|up)|bundle${opts}[[:space:]]+(install|update|add)|gem${opts}[[:space:]]+install|pip3?${opts}[[:space:]]+(install|uninstall)|python3?${opts}[[:space:]]+-m[[:space:]]+pip${opts}[[:space:]]+(install|uninstall)|uv${opts}[[:space:]]+(add|remove|sync|lock|pip[[:space:]]+(install|uninstall|sync))|poetry${opts}[[:space:]]+(add|remove|install|update|lock|sync)|composer${opts}[[:space:]]+(install|require|update|remove)|cargo${opts}[[:space:]]+(add|install|update|remove)|go${opts}[[:space:]]+get|brew${opts}[[:space:]]+(install|upgrade))([[:space:]]|$)"
    grep -Eq "$pkg_re" <<<"$cmd" &&
      deny "依存パッケージのインストール・更新はできません（依存フォルダはもとのリポジトリへのリンクです）。必要なら報告に書いてください"
    # uv run は既定で依存環境を同期し、リンクした .venv（もとのリポジトリのもの）を書き換える
    if grep -Eq "${sep}uv${opts}[[:space:]]+run([[:space:]]|$)" <<<"$cmd" && ! grep -Eq -- '--no-sync([[:space:]]|$)' <<<"$cmd"; then
      deny "uv run は依存環境を同期してリンク先の .venv を書き換えるので、--no-sync を付けてください（例: uv run --no-sync pytest）"
    fi
    ;;
esac
exit 0
