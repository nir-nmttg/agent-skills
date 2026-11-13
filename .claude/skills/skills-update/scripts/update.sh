#!/usr/bin/env bash
# agent-skills を origin の既定ブランチまで fast-forward し、Claude Code・Codex へリンクし直して、
# skills-preflight の確認結果を Markdown で出力する。
#
# 使い方: update.sh
#   - メインの checkout が既定ブランチ（origin/HEAD、取れなければ main）にいるときだけ、取り込みとリンクを行う
#   - 取り込みは git fetch origin <既定ブランチ> のあと merge --ff-only --no-autostash。
#     未コミットの変更が衝突する・履歴が分かれているときは、作業ツリーを変えずに取り込みを飛ばす
#   - git worktree の中から呼ばれたら、メインの checkout の update.sh に引き継ぐ
#   - 終了コードは常に 0（スキルの読み込み時に実行するため）
set -uo pipefail

# 取り込みで自分自身が書き換わっても、読み込み済みの main を最後まで実行する
main() {
  local repo_root git_dir common_dir main_root target
  repo_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)

  if ! command -v git >/dev/null 2>&1; then
    printf '## 更新\n\n`git` が見つからないので、取り込みもリンクもしていません。\n\n'
    run_checks "$repo_root"
    return
  fi
  if ! git_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    ! common_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    printf '## 更新\n\n%s を git リポジトリと判定できないので、取り込みもリンクもしていません。\n\n' "$repo_root"
    run_checks "$repo_root"
    return
  fi

  # worktree の中を更新・リンクすると、片付けたときにリンクが切れるので、メインの checkout に任せる
  if [[ $git_dir != "$common_dir" ]]; then
    main_root=$(dirname "$common_dir")
    target="$main_root/.claude/skills/skills-update/scripts/update.sh"
    if [[ -z ${SKILLS_UPDATE_FROM_WORKTREE:-} && -f $target ]]; then
      SKILLS_UPDATE_FROM_WORKTREE=1 exec bash "$target"
    fi
    printf '## 更新\n\ngit worktree の中なので、取り込みもリンクもしていません。メインの checkout（%s）から実行し直してください。\n\n' "$main_root"
    run_checks "$repo_root"
    return
  fi

  local default_branch branch can_link=false
  default_branch=$(git -C "$repo_root" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
  default_branch=${default_branch#origin/}
  default_branch=${default_branch:-main}
  branch=$(git -C "$repo_root" symbolic-ref --short -q HEAD 2>/dev/null)

  echo "## 更新"
  echo
  [[ -z ${SKILLS_UPDATE_FROM_WORKTREE:-} ]] || echo "git worktree から呼ばれたので、メインの checkout（${repo_root}）で実行しました。"
  if [[ $branch != "$default_branch" ]]; then
    # 作業中のブランチの内容を全プロジェクトにリンクしないよう、リンクも飛ばす
    echo "メインの checkout（${repo_root}）が ${branch:-detached HEAD} にあり、${default_branch} ではないので、取り込みもリンクもしていません。"
    echo "$default_branch に戻してから実行し直してください。"
  else
    can_link=true
    update "$repo_root" "$default_branch"
  fi
  echo

  echo "## リンク"
  echo
  if $can_link; then
    link "$repo_root"
  else
    echo "飛ばしました（上の「更新」を参照）。"
  fi
  echo

  run_checks "$repo_root"
}

# update <repo_root> <既定ブランチ>
update() {
  local repo_root=$1 default_branch=$2 out before after count
  # 鍵のパスフレーズ・ホスト鍵の確認などで入力待ちにならないようにする。
  # ssh の設定がすでにあれば、その後ろにオプションを足す（ssh は同じオプションの最初の値を使うので、利用者の指定が優先される。
  # -o を受け付けないラッパーを設定している場合は取得に失敗し、その旨を表示する）
  local ssh_command
  export GIT_TERMINAL_PROMPT=0
  ssh_command=${GIT_SSH_COMMAND:-$(git -C "$repo_root" config core.sshCommand 2>/dev/null)}
  export GIT_SSH_COMMAND="${ssh_command:-ssh} -o BatchMode=yes -o ConnectTimeout=10"

  if ! out=$(git -C "$repo_root" fetch --quiet origin "+refs/heads/$default_branch:refs/remotes/origin/$default_branch" </dev/null 2>&1); then
    echo "origin から取得できなかったので、手元の $default_branch のままリンクします。"
    code_block "$out"
    return
  fi

  before=$(git -C "$repo_root" rev-parse --short HEAD)
  if ! out=$(git -C "$repo_root" merge --ff-only --no-autostash "origin/$default_branch" </dev/null 2>&1); then
    echo "origin/$default_branch を取り込めなかったので（未コミットの変更との衝突・履歴の分岐など）、手元の $default_branch のままリンクします。"
    code_block "$out"
    return
  fi
  after=$(git -C "$repo_root" rev-parse --short HEAD)

  if [[ $before == "$after" ]]; then
    echo "最新です（${after}）。"
    return
  fi
  count=$(git -C "$repo_root" rev-list --count "$before..$after")
  echo "$before → $after に更新しました（$count 件のコミット）。"
  code_block "$(git -C "$repo_root" log --oneline --no-decorate -20 "$before..$after")"
  ((count <= 20)) || echo "（新しい 20 件だけ表示）"
}

# link <repo_root>
link() {
  local repo_root=$1 script out status changes
  script="$repo_root/scripts/link-skills.sh"
  if [[ ! -f $script ]]; then
    echo "\`scripts/link-skills.sh\` が見つからないので、リンクしていません。"
    return
  fi
  out=$(bash "$script" </dev/null 2>&1)
  status=$?
  if ((status != 0)); then
    echo "リンクに失敗しました（終了コード ${status}）。"
    code_block "$out"
    return
  fi
  changes=$(grep -E '^(added|relinked|removed|skip) ' <<<"$out")
  if [[ -z $changes ]]; then
    echo "変更なし（Claude Code・Codex とも、すべてリンク済み）。"
    return
  fi
  # どちら向けの変更かわかるよう、[Claude Code] などの見出し行も残す
  code_block "$(grep -E '^(\[|(added|relinked|removed|skip) )' <<<"$out")"
  if grep -q '^added ' <<<"$changes"; then
    echo "新しく入ったスキル・サブエージェントは、新しいセッション（Codex は再起動）から使えることがあります。"
  fi
}

# run_checks <repo_root>: skills-preflight の確認スクリプトを実行し、見出しを下げて載せる
run_checks() {
  local repo_root=$1
  echo "## 確認結果"
  echo
  echo "### Claude Code"
  echo
  run_check "$repo_root/.claude/skills/skills-preflight/scripts/check.sh"
  echo
  echo "### Codex（定義とリンクの状態）"
  echo
  echo "スキルごとの利用可否は、Codex から \`\$skills-preflight\` で確かめてください。"
  echo
  run_check "$repo_root/.agents/skills/skills-preflight/scripts/check.sh"
}

# run_check <check.sh>
run_check() {
  local script=$1 out status
  if [[ ! -f $script ]]; then
    echo "\`$script\` が見つかりません。"
    return
  fi
  out=$(bash "$script" </dev/null 2>&1)
  status=$?
  LC_ALL=C sed 's/^## /#### /' <<<"$out"
  ((status == 0)) || echo "（確認スクリプトが終了コード $status で終わりました）"
}

# code_block <text>
code_block() {
  [[ -n $1 ]] || return 0
  echo '```text'
  echo "$1"
  echo '```'
}

main "$@"; exit 0
