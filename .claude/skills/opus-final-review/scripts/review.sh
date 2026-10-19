#!/usr/bin/env bash
# 作業フォルダの git の変更を、会話を共有しない Claude（Opus 5.5）に要件だけを渡して読み取り専用でレビューさせ、review.md に保存する。
#
# 使い方: review.sh --effort <low|medium|high|xhigh|max> [--cd <dir>] [--base <ref> | --commit <sha> | --uncommitted] <実行フォルダ>
#   --effort       Opus の推論レベル。Claude の推論レベルをそのまま渡す（省略時は $CLAUDE_EFFORT、それもなければ high）
#   --cd           レビューするリポジトリ（既定: 今のフォルダ）
#   --base         <ref> から分岐して以降の変更（コミット済み＋未コミット）をレビューする
#   --commit       1 つのコミットだけをレビューする
#   --uncommitted  未コミットの変更（ステージ済み・未ステージ・未追跡）だけをレビューする
#   範囲を指定しなければ、既定ブランチ（origin/HEAD、なければ main / master）からの変更をすべてレビューする。
#
# 環境変数 OPUS_FINAL_REVIEW_MODEL でモデルを変えられる（既定: claude-opus-5-5）。
set -euo pipefail

usage() { sed -n '4,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

effort="" workdir=$PWD run_dir="" mode=auto target=""
while (($#)); do
  case $1 in
    --effort) effort=${2:-}; shift 2 || usage ;;
    --cd) workdir=${2:-}; shift 2 || usage ;;
    --base | --commit)
      [[ $mode == auto ]] || usage
      mode=${1#--}; target=${2:-}; [[ -n $target ]] || usage; shift 2 ;;
    --uncommitted) [[ $mode == auto ]] || usage; mode=uncommitted; shift ;;
    -*) usage ;;
    *) [[ -z $run_dir ]] || usage; run_dir=$1; shift ;;
  esac
done
[[ -n $run_dir ]] || usage

model=${OPUS_FINAL_REVIEW_MODEL:-claude-opus-5-5}
prompt_file=$(dirname "$0")/../assets/review-prompt.md
effort=${effort:-${CLAUDE_EFFORT:-}}
case $effort in
  low | medium | high | xhigh | max) ;;
  "" | auto) echo "注意: Claude の推論レベルがわからないため high で実行します" >&2; effort=high ;;
  *) echo "エラー: 推論レベル '$effort' には対応していません（low / medium / high / xhigh / max）" >&2; exit 1 ;;
esac

command -v claude >/dev/null || { echo "エラー: claude コマンドが見つかりません" >&2; exit 1; }
command -v jq >/dev/null || { echo "エラー: jq コマンドが見つかりません（brew install jq）" >&2; exit 1; }
[[ -f $prompt_file ]] || { echo "エラー: レビューの指示書 $prompt_file がありません" >&2; exit 1; }
[[ -s $run_dir/requirements.md ]] || { echo "エラー: $run_dir/requirements.md がないか空です" >&2; exit 1; }
[[ -d $workdir ]] || { echo "エラー: 作業フォルダ $workdir がありません" >&2; exit 1; }
run_dir=$(cd -P "$run_dir" && pwd)
toplevel=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || { echo "エラー: $workdir は git リポジトリではありません" >&2; exit 1; }
workdir=$toplevel
git -C "$workdir" rev-parse -q --verify HEAD >/dev/null || { echo "エラー: $workdir にはまだコミットがありません" >&2; exit 1; }

g() { git -C "$workdir" "$@"; }

# レビューする範囲を決め、差分を diff.patch に書き出す
untracked=()
if [[ $mode == commit ]]; then
  sha=$(g rev-parse -q --verify "$target^{commit}") || { echo "エラー: コミット '$target' が見つかりません" >&2; exit 1; }
  scope="コミット $(g log -1 --format='%h %s' "$sha")"
  # コミットメッセージには作成者の説明が入るので、件名だけを渡す
  commits=$(g log -1 --format='%h %s' "$sha")
  # マージコミットは combined diff だと取り込んだ変更が出ないので、第一親との差分にする
  if g rev-parse -q --verify "$sha^1" >/dev/null; then
    view_cmd="git diff $sha^1 $sha"
    stat=$(g diff --stat "$sha^1" "$sha")
    g diff "$sha^1" "$sha" >"$run_dir/diff.patch"
  else
    view_cmd="git show $sha"
    stat=$(g show --format= --stat "$sha")
    g show --format= --patch "$sha" >"$run_dir/diff.patch"
  fi
else
  if [[ $mode == uncommitted ]]; then
    from=$(g rev-parse HEAD)
    scope="未コミットの変更（HEAD $(g rev-parse --short HEAD) からの差分）"
  else
    if [[ $mode == auto ]]; then
      target=$(g symbolic-ref -q --short refs/remotes/origin/HEAD) ||
        for b in main master; do g rev-parse -q --verify "$b^{commit}" >/dev/null && { target=$b; break; }; done
      [[ -n $target ]] || { echo "エラー: 既定ブランチがわかりません。--base か --commit か --uncommitted で範囲を指定してください" >&2; exit 1; }
    fi
    g rev-parse -q --verify "$target^{commit}" >/dev/null || { echo "エラー: '$target' が見つかりません" >&2; exit 1; }
    from=$(g merge-base "$target" HEAD) || { echo "エラー: '$target' と HEAD の共通の祖先がありません" >&2; exit 1; }
    scope="$target から分岐して以降の変更（$(g rev-parse --short "$from") からの差分。未コミットの変更を含む）"
  fi
  view_cmd="git diff $from"
  commits=$(g log --format='%h %s' "$from..HEAD")
  stat=$(g diff --stat "$from")
  g diff "$from" >"$run_dir/diff.patch"
  while IFS= read -r -d '' f; do untracked+=("$f"); done < <(g ls-files -z --others --exclude-standard)
  for f in ${untracked[@]+"${untracked[@]}"}; do
    # --no-index は差分があると 1 で終わる。それ以外の失敗は取りこぼしになるので止める
    rc=0
    (cd "$workdir" && git diff --no-index -- /dev/null "$f" >>"$run_dir/diff.patch") || rc=$?
    ((rc <= 1)) || { echo "エラー: 未追跡ファイル '$f' の差分を作れませんでした" >&2; exit 1; }
  done
fi

if [[ ! -s $run_dir/diff.patch ]]; then
  echo "エラー: レビューする変更がありません（範囲: ${scope}）。--base / --commit / --uncommitted で範囲を指定してください" >&2
  exit 1
fi
files=$(grep -c '^diff --git ' "$run_dir/diff.patch" || true)
lines=$(grep -E '^[+-]' "$run_dir/diff.patch" | grep -cvE '^(\+\+\+|---) ' || true)

# 大きすぎる差分はプロンプトに埋め込まず、git コマンドで読ませる
max_bytes=200000
size=$(wc -c <"$run_dir/diff.patch" | tr -d ' ')

{
  cat "$prompt_file"
  printf '\n\n<scope>\n'
  echo "リポジトリ: $workdir"
  echo "範囲: $scope"
  if [[ -n $commits ]]; then printf '\nコミット:\n%s\n' "$commits"; fi
  if [[ -n $stat ]]; then printf '\n変更ファイル:\n%s\n' "$stat"; fi
  if ((${#untracked[@]})); then printf '\n未追跡の新規ファイル:\n'; printf '%s\n' "${untracked[@]}"; fi
  printf '</scope>\n\n<requirements>\n'
  cat "$run_dir/requirements.md"
  printf '\n</requirements>\n\n<diff>\n'
  if ((size <= max_bytes)); then
    cat "$run_dir/diff.patch"
  else
    echo "差分が大きい（${size} バイト）ため埋め込んでいません。\`$view_cmd\` で確認してください（未追跡の新規ファイルは直接読んでください）。"
  fi
  printf '</diff>\n'
} >"$run_dir/prompt.md"

# 読み取り専用で動かす:
# - --restricted: ユーザー・プロジェクトの設定ファイル（フックなど）を読まず、ファイル操作を作業フォルダに閉じる
# - --tools: 使えるツールを読み取りと Bash だけにし、Bash は下の読み取り専用の git コマンドだけを許可する
# - dontAsk + --permission-prompts none: 許可していない操作は確認せずに拒否する
# - --strict-mcp-config / --disable-slash-commands: MCP サーバーとスキルを読み込まない
git_ro=(log show diff blame status ls-files grep rev-parse merge-base cat-file)
allowed=(Read Grep Glob)
for c in "${git_ro[@]}"; do allowed+=("Bash(git $c)" "Bash(git $c *)"); done
args=(
  -p
  --model "$model"
  --effort "$effort"
  --restricted
  --tools Read,Grep,Glob,Bash
  --allowedTools "${allowed[@]}"
  --permission-mode dontAsk
  --permission-prompts none
  --strict-mcp-config
  --disable-slash-commands
  --output-format json
)

echo "Opus でレビュー中: model=$model effort=$effort 範囲=${scope}（$files ファイル、$lines 行）" >&2
started=$SECONDS
status=0
(cd "$workdir" && claude "${args[@]}" <"$run_dir/prompt.md") >"$run_dir/result.json" 2>"$run_dir/claude.log" || status=$?

if ((status != 0)) || ! jq -e '.is_error == false and (.result | type == "string" and length > 0)' "$run_dir/result.json" >/dev/null 2>&1; then
  echo "エラー: Opus の実行に失敗しました（終了コード ${status}）" >&2
  jq -r '.result // empty' "$run_dir/result.json" 2>/dev/null | tail -5 >&2 || true
  tail -20 "$run_dir/claude.log" >&2
  if [[ $(jq -r '.api_error_code // empty' "$run_dir/result.json" 2>/dev/null) == claude_code_version_too_old ]]; then
    echo "claude CLI（$(command -v claude)、$(claude --version 2>/dev/null)）が古いため、$model を使えません。claude update（Homebrew なら brew upgrade --cask claude-code）で更新してください" >&2
  fi
  exit 1
fi
jq -r '.result' "$run_dir/result.json" >"$run_dir/review.md"

session=$(jq -r '.session_id // "不明"' "$run_dir/result.json")
usage_line=$(jq -r '.usage | "入力 \((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) / 出力 \(.output_tokens // 0)"' "$run_dir/result.json" 2>/dev/null || echo 不明)
cost=$(jq -r '.total_cost_usd // empty | "\(. * 100 | round / 100) USD 相当"' "$run_dir/result.json" 2>/dev/null || true)
denied=$(jq -r '[.permission_denials[]? | .tool_input.command // .tool_name] | unique | join(", ")' "$run_dir/result.json" 2>/dev/null || true)

echo "## Opus の最終レビュー（要件だけを渡したレビュー）"
echo
echo "- 設定: $model / effort=$effort"
echo "- 範囲: ${scope}（$files ファイル、$lines 行）"
echo "- 所要時間: $((SECONDS - started)) 秒、トークン: $usage_line${cost:+、$cost}"
echo "- 保存先: $run_dir/review.md"
echo "- 続きを Opus と話す: (cd $workdir && claude --resume $session)"
[[ -z $denied ]] || echo "- 拒否された操作: $denied"
echo
cat "$run_dir/review.md"
echo
