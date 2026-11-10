#!/usr/bin/env bash
# Auto-fix で起こされたときに、PR へ返信・まとめ・上限の案内を書く。先頭にマーカーを付け、pr-feedback.sh が対応済みの印として読む。
#
# 使い方: pr-comment.sh <PR の URL か番号> --reply <スレッドの最初のコメントの ID> --read <読んだ最後のコメントの ID> --read-at <読んだ時刻>  # 本文は標準入力
#         pr-comment.sh <PR の URL か番号> --summary --read-at <読んだ時刻> --result done|stopped [--reason <理由>] [--answered <ID,…>]
#                       [--ci-checked <ID,…>] [--conflict-checked <head>-<base>]                             # 本文は標準入力
#         pr-comment.sh <PR の URL か番号> --limit
#   --reply: レビューのスレッドに返信する（1000 文字まで）。--read と --read-at は pr-feedback.sh が出した値
#     （読んだ時刻より後に編集された書き込みは、pr-feedback.sh がもう一度未対応として出す）。
#   --summary: 会話欄に対応のまとめを書く（3000 文字まで）。--answered は、このまとめで答えたレビューの本文（r…）と会話欄のコメント（c…）の ID。
#     --ci-checked は調べた CI の失敗の ID、--conflict-checked は解消できなかった競合（pr-feedback.sh が出した値）。
#   --reason（--result stopped のとき）: checks | review | verify | spec | unclear | denied | env | other
#   --limit: 自動の対応が上限に達して Auto-fix をオフにしたことを、定型文で書く。
#   本文は、HTML コメントを取り除き、URL・画像・リンクの記法を [URL] にし、@ をメンションにならない形にする（コミットの sha と #番号は残す）。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPLY_LIMIT=1000
SUMMARY_LIMIT=3000

TARGET= MODE= REPLY_TO= READ= READ_AT= RESULT= REASON= ANSWERED= CI_CHECKED= CONFLICT_CHECKED=
while (($#)); do
  case $1 in
    --reply | --read | --read-at | --result | --reason | --answered | --ci-checked | --conflict-checked)
      (($# >= 2)) || die "$1 に値を指定してください。"
      case $1 in
        --reply) MODE=${MODE:-reply}; REPLY_TO=$2 ;;
        --read) READ=$2 ;;
        --read-at) READ_AT=$2 ;;
        --result) RESULT=$2 ;;
        --reason) REASON=$2 ;;
        --answered) ANSWERED=$2 ;;
        --ci-checked) CI_CHECKED=$2 ;;
        --conflict-checked) CONFLICT_CHECKED=$2 ;;
      esac
      shift 2
      ;;
    --summary) [[ -z $MODE ]] || die "--reply・--summary・--limit は 1 つだけ指定してください。"; MODE=summary; shift ;;
    --limit) [[ -z $MODE ]] || die "--reply・--summary・--limit は 1 つだけ指定してください。"; MODE=limit; shift ;;
    -*) die "不明なオプション: $1" ;;
    *) [[ -z $TARGET ]] || die "PR は 1 つだけ指定してください。"; TARGET=$1; shift ;;
  esac
done
[[ -n $MODE ]] || die "--reply・--summary・--limit のどれかを指定してください。"

require_tools
command -v perl >/dev/null 2>&1 || die "perl がありません。"
load_repo
TARGET=${TARGET#\#}
if [[ $TARGET =~ ^[1-9][0-9]*$ ]]; then
  NUMBER=$TARGET
elif [[ $(tr '[:upper:]' '[:lower:]' <<<"$TARGET") =~ ^https://(www\.)?github\.com/([^/]+/[^/]+)/pull/0*([1-9][0-9]*)$ ]] &&
  [[ ${BASH_REMATCH[2]} == $(tr '[:upper:]' '[:lower:]' <<<"$REPO") ]]; then
  NUMBER=${BASH_REMATCH[3]}
else
  die "$REPO の PR の URL か番号を指定してください: ${TARGET:-（なし）}"
fi

# 標準入力の本文を整える（1 行目のマーカーを偽れないように、HTML コメントは残さない）
read_body() {
  local limit=$1 text
  text=$(perl -CSD -0777 -pe '
    s/<!--.*?-->//gs; s/<!--.*//gs;
    s{!\[[^\]]*\]\([^)]*\)}{[URL]}g;
    s{\[([^\]]*)\]\([^)]*\)}{$1 [URL]}g;
    s{(?:https?:)?//\S+}{[URL]}gi; s{\bwww\.\S+}{[URL]}gi;
    s/\@/\x{FF20}/g;
    s/\s+$//; s/^\s+//;
    $_ = substr($_, 0, '"$limit"') . (length($_) > '"$limit"' ? "\x{2026}" : "");
  ')
  [[ -n $text ]] || die "本文が空です。標準入力で渡してください。"
  printf '%s' "$text"
}

if [[ $MODE != limit ]]; then
  [[ $READ_AT =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    die "--read-at には pr-feedback.sh が出した「読んだ時刻」（例 2026-11-10T01:00:00Z）を指定してください: ${READ_AT:-（なし）}"
fi

case $MODE in
  reply)
    [[ $REPLY_TO =~ ^[1-9][0-9]*$ ]] || die "--reply にはコメントの ID（数字）を指定してください: $REPLY_TO"
    [[ $READ =~ ^[1-9][0-9]*$ ]] || die "--read には pr-feedback.sh が出した ID（数字）を指定してください: ${READ:-（なし）}"
    [[ -z $RESULT$REASON$ANSWERED$CI_CHECKED$CONFLICT_CHECKED ]] || die "--reply には --read のほかのオプションを付けません。"
    body="<!-- gh-issue-auto-pr:pr-reply v=1 read-at=$READ_AT read=$READ -->
🤖 gh-issue-auto-pr: $(read_body "$REPLY_LIMIT")"
    url=$(gh api --method POST "repos/$REPO/pulls/$NUMBER/comments/$REPLY_TO/replies" -f body="$body" --jq .html_url) ||
      die "スレッド（コメント $REPLY_TO）に返信できませんでした。"
    echo "返信しました: $url"
    ;;
  summary)
    [[ $RESULT == done || $RESULT == stopped ]] || die "--result は done か stopped です: ${RESULT:-（なし）}"
    [[ -z $READ$REPLY_TO ]] || die "--summary には --reply・--read を付けません。"
    [[ -z $ANSWERED || $ANSWERED =~ ^[rc][0-9]+(,[rc][0-9]+)*$ ]] || die "--answered は r123,c456 の形にしてください: $ANSWERED"
    [[ -z $CI_CHECKED || $CI_CHECKED =~ ^[A-Za-z0-9_=+/-]+(,[A-Za-z0-9_=+/-]+)*$ ]] || die "--ci-checked は pr-feedback.sh が出した ID をカンマで区切ってください: $CI_CHECKED"
    [[ -z $CONFLICT_CHECKED || $CONFLICT_CHECKED =~ ^[0-9a-f]{7,40}-[0-9a-f]{7,40}$ ]] || die "--conflict-checked は pr-feedback.sh が出した値にしてください: $CONFLICT_CHECKED"
    if [[ $RESULT == done ]]; then
      [[ -z $REASON ]] || die "--reason は --result stopped のときだけ付けます。"
      head="🤖 gh-issue-auto-pr が、この PR への指摘・CI・競合に対応しました。"
    else
      case $REASON in
        checks) reason_text="テスト・lint・型チェックが通りませんでした。" ;;
        review) reason_text="レビューで重要度の高い指摘が残りました。" ;;
        verify) reason_text="動作確認で満たせませんでした。" ;;
        spec) reason_text="受け入れ条件か既存の仕様を変えないと対応できません。" ;;
        unclear) reason_text="指摘の意図や直し方を決められませんでした。" ;;
        denied) reason_text="必要な操作が許可されませんでした。" ;;
        env) reason_text="実行環境の問題で進められませんでした。" ;;
        other) reason_text="上のどれにも当てはまらない理由で止めました。" ;;
        *) die "--reason は checks | review | verify | spec | unclear | denied | env | other のどれかです: ${REASON:-（なし）}" ;;
      esac
      head="🤖 gh-issue-auto-pr が、この PR への対応を途中で止めました。理由: $reason_text"
    fi
    mark="<!-- gh-issue-auto-pr:pr-handled v=1 read-at=$READ_AT result=$RESULT${ANSWERED:+ answered=$ANSWERED}${CI_CHECKED:+ ci-checked=$CI_CHECKED}${CONFLICT_CHECKED:+ conflict-checked=$CONFLICT_CHECKED} -->"
    body="$mark
$head

$(read_body "$SUMMARY_LIMIT")"
    url=$(gh pr comment "$NUMBER" --repo "$REPO" --body-file - <<<"$body") || die "PR #$NUMBER にまとめをコメントできませんでした。"
    echo "まとめをコメントしました: $url"
    ;;
  limit)
    [[ -z $READ$READ_AT$REPLY_TO$RESULT$REASON$ANSWERED$CI_CHECKED$CONFLICT_CHECKED ]] || die "--limit には、ほかのオプションを付けません。"
    body="<!-- gh-issue-auto-pr:pr-limit -->
🤖 gh-issue-auto-pr の自動の対応が上限に達したので、この PR の Auto-fix をオフにしました。続けるときは、Claude デスクトップアプリでこの PR のセッションの Auto-fix をオンにし直してください。"
    url=$(gh pr comment "$NUMBER" --repo "$REPO" --body-file - <<<"$body") || die "PR #$NUMBER に上限の案内をコメントできませんでした。"
    echo "上限の案内をコメントしました: $url"
    ;;
esac
