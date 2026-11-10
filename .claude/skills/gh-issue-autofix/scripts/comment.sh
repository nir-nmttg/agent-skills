#!/usr/bin/env bash
# 止めた Issue に理由をコメントする。本文はテンプレートで組み立て、自由に書ける部分は短い補足だけにする
# （Issue の文言がそのまま投稿されないようにするため）。
#
# 使い方: comment.sh <Issue の番号> --reason <理由> --stage <段階> --resume auto|manual [--read-at <時刻>] [--pr <PR の URL>] [--detail -]
#   --reason: unclear | spec | checks | review | verify | unreviewed | denied | env | other
#   --stage:  investigate | implement | check | review | verify | publish
#   --resume: auto = Issue を更新すれば次の実行で再開する（ブランチも PR も残らない）
#             manual = ブランチか PR が残るので /gh-issue-autofix <URL> で再開する
#   --read-at: find-issue.sh が出した「読んだ時刻」。これより後の更新があれば、次の実行で再開する
#   --detail -: 補足を標準入力から読む（300 文字まで。URL・メンション・Issue の参照・HTML コメントは取り除く）
#   本文の先頭に停止のマーカーを付ける。find-issue.sh はこれを見て、Issue が更新されるまで自動では選ばない。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DETAIL_LIMIT=300

NUMBER= REASON= STAGE= RESUME= PR= READ_AT= DETAIL=false
while (($#)); do
  case $1 in
    --reason | --stage | --resume | --pr | --read-at | --detail)
      (($# >= 2)) || die "$1 に値を指定してください。"
      case $1 in
        --reason) REASON=$2 ;;
        --stage) STAGE=$2 ;;
        --resume) RESUME=$2 ;;
        --pr) PR=$2 ;;
        --read-at) READ_AT=$2 ;;
        --detail) [[ $2 == - ]] || die "--detail には - を指定し、補足を標準入力で渡してください。"; DETAIL=true ;;
      esac
      shift 2
      ;;
    -*) die "不明なオプション: $1" ;;
    *) [[ -z $NUMBER ]] || die "Issue の番号は 1 つだけ指定してください。"; NUMBER=$1; shift ;;
  esac
done
require_number "$NUMBER"

case $REASON in
  unclear) reason_text="Issue の内容から直し方を決められませんでした。" ;;
  spec) reason_text="受け入れ条件か既存の仕様を変えないと直せないため、止めました。" ;;
  checks) reason_text="テスト・lint・型チェックが通りませんでした。" ;;
  review) reason_text="レビューで重要度の高い指摘が残りました。" ;;
  verify) reason_text="動作確認で受け入れ条件を満たせませんでした。" ;;
  unreviewed) reason_text="自動で書いた変更をレビューできなかったため、push していません。" ;;
  denied) reason_text="必要な操作が許可されませんでした。" ;;
  env) reason_text="実行環境の問題で進められませんでした。" ;;
  other) reason_text="上のどれにも当てはまらない理由で止めました。" ;;
  *) die "--reason は unclear | spec | checks | review | verify | unreviewed | denied | env | other のどれかです: ${REASON:-（なし）}" ;;
esac
case $STAGE in
  investigate) stage_text="調査" ;;
  implement) stage_text="実装" ;;
  check) stage_text="テスト・実装ルールの確認" ;;
  review) stage_text="レビュー" ;;
  verify) stage_text="動作確認" ;;
  publish) stage_text="PR の作成" ;;
  *) die "--stage は investigate | implement | check | review | verify | publish のどれかです: ${STAGE:-（なし）}" ;;
esac
[[ $RESUME == auto || $RESUME == manual ]] || die "--resume は auto か manual です: ${RESUME:-（なし）}"
[[ -z $READ_AT || $READ_AT =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  die "--read-at は find-issue.sh が出した時刻（例 2026-11-10T01:00:00Z）にしてください: $READ_AT"
STOP_MARK="<!-- gh-issue-autofix:stopped${READ_AT:+ read-at=$READ_AT} -->"

require_tools
command -v perl >/dev/null 2>&1 || die "perl がありません。"
load_repo
BRANCH=$(branch_name "$NUMBER")
if [[ -n $PR ]]; then
  [[ $(tr '[:upper:]' '[:lower:]' <<<"$PR") =~ ^https://github\.com/$(tr '[:upper:]' '[:lower:]' <<<"$REPO")/pull/[1-9][0-9]*$ ]] ||
    die "--pr は https://github.com/$REPO/pull/<番号> の形にしてください: $PR"
fi

detail=
if $DETAIL; then
  # 1 行にまとめ、HTML コメント・URL・メンションを取り除き、300 文字で切る
  detail=$(perl -CSD -0777 -pe '
    s/<!--.*?-->//gs; s/<!--.*//gs;
    s{(?:https?:)?//\S+}{[URL]}gi; s{\bwww\.\S+}{[URL]}gi;
    s/\@/\x{FF20}/g; s/#(?=\d)/#\x{200B}/g;
    s/\s+/ /g; s/^ //; s/ $//;
    $_ = substr($_, 0, '"$DETAIL_LIMIT"') . (length($_) > '"$DETAIL_LIMIT"' ? "…" : "");
  ')
fi

if [[ $RESUME == auto ]]; then
  resume_text="この Issue の本文を編集するか、コメントで情報を足すと、次の定期実行で自動で再開します（\`agent:autofix\` ラベルと担当者の設定が残っている場合）。"
else
  resume_text="ブランチ \`$BRANCH\` か PR が残っているので、自動では再開しません。続きから進めるときは \`/gh-issue-autofix <この Issue の URL>\` を実行してください。"
fi

body=$(
  echo "$STOP_MARK"
  echo "🤖 gh-issue-autofix がこの Issue の対応を止めました。"
  echo
  echo "- 理由: $reason_text"
  echo "- 止めた段階: $stage_text"
  [[ -z $PR ]] || echo "- ドラフト PR: $PR"
  [[ -z $detail ]] || echo "- 補足: $detail"
  echo
  echo "$resume_text"
)

url=$(gh issue comment "$NUMBER" --repo "$REPO" --body-file - <<<"$body") ||
  die "#$NUMBER にコメントできませんでした。"
echo "コメントしました: $url"
