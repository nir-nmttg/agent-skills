#!/usr/bin/env bash
# 止めた Issue に理由をコメントする（または、再開したことを記録する）。本文はテンプレートで組み立て、自由に書ける部分は短い補足だけにする
# （Issue の文言がそのまま投稿されないようにするため）。
#
# 使い方: comment.sh <Issue の番号> --reason <理由> --stage <段階> --resume new|continue [--read-at <時刻>] [--pr <PR の URL>] [--detail -]
#         comment.sh <Issue の番号> --resumed
#   --reason: unclear | spec | checks | review | verify | unreviewed | denied | env | other
#   --stage:  investigate | implement | check | review | verify | publish
#   --resume: new      = ブランチも PR も残らない。Issue を更新すると、次の定期実行で最初からやり直す
#             continue = ブランチか PR が残る。Issue を更新すると、次の定期実行でその続きから再開する
#   --read-at: find-issue.sh が出した「読んだ時刻」。これより後の更新があれば、次の実行で再開する
#   --detail -: 補足を標準入力から読む（300 文字まで。URL・メンション・Issue の参照・HTML コメントは取り除く）
#   本文の先頭に停止のマーカーを付ける。find-issue.sh はこれを見て、Issue が更新されるまで自動では選ばない。
#   --resumed: 停止したことのある Issue に着手した直後に、再開の記録（マーカーと定型文だけ）を書く。
#     find-issue.sh は、最新のマーカーがこれなら選ばない（同じ更新で選び直さない）。ほかのオプションは取らない。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DETAIL_LIMIT=300

NUMBER= REASON= STAGE= RESUME= PR= READ_AT= DETAIL=false RESUMED=false
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
    --resumed) RESUMED=true; shift ;;
    -*) die "不明なオプション: $1" ;;
    *) [[ -z $NUMBER ]] || die "Issue の番号は 1 つだけ指定してください。"; NUMBER=$1; shift ;;
  esac
done
require_number "$NUMBER"

if $RESUMED; then
  [[ -z $REASON$STAGE$RESUME$PR$READ_AT ]] && ! $DETAIL || die "--resumed には、ほかのオプションを付けません。"
  require_tools
  load_repo
  body=$(
    echo "<!-- gh-issue-autofix:resumed -->"
    echo "🤖 gh-issue-autofix がこの Issue の対応を再開しました。結果は、ドラフト PR か、このあとのコメントでお知らせします。"
  )
  url=$(gh issue comment "$NUMBER" --repo "$REPO" --body-file - <<<"$body") ||
    die "#$NUMBER に再開の記録をコメントできませんでした。"
  echo "再開の記録をコメントしました: $url"
  exit 0
fi

case $REASON in
  unclear) reason_text="Issue の内容から直し方を決められませんでした。" ;;
  spec) reason_text="受け入れ条件か既存の仕様を変えないと直せないため、止めました。" ;;
  checks) reason_text="テスト・lint・型チェックが通りませんでした。" ;;
  review) reason_text="レビューで重要度の高い指摘が残りました。" ;;
  verify) reason_text="動作確認で受け入れ条件を満たせませんでした。" ;;
  unreviewed) reason_text="自動で書いた変更をレビューできませんでした。" ;;
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
[[ $RESUME == new || $RESUME == continue ]] || die "--resume は new か continue です: ${RESUME:-（なし）}"
[[ -z $READ_AT || $READ_AT =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  die "--read-at は find-issue.sh が出した時刻（例 2026-11-10T01:00:00Z）にしてください: $READ_AT"
# v=2: ブランチや PR が残っていても、Issue の更新で自動で再開する版の停止コメント（find-issue.sh が旧版と見分ける）
STOP_MARK="<!-- gh-issue-autofix:stopped v=2${READ_AT:+ read-at=$READ_AT} -->"

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
    $_ = substr($_, 0, '"$DETAIL_LIMIT"') . (length($_) > '"$DETAIL_LIMIT"' ? "\x{2026}" : "");
  ')
fi

# 再開の条件（ラベル・担当・PR）。PR へのコメントや、PR を Issue に手で紐づけたときは再開しない
conditions="\`agent:autofix\` ラベルと担当者の設定が残っている場合"
if [[ $RESUME == new ]]; then
  resume_text="この Issue の本文を編集するか、コメントで情報を足すと、次の定期実行で最初からやり直します（$conditions）。"
elif [[ -n $PR ]]; then
  resume_text="この Issue の本文を編集するか、コメントで方針や情報を足すと、次の定期実行でドラフト PR の続きから再開します（$conditions。PR がドラフトのままで、PR を Issue に紐づけていない場合。PR へのコメントでは再開しません）。"
else
  resume_text="この Issue の本文を編集するか、コメントで方針や情報を足すと、次の定期実行でブランチ \`$BRANCH\` の続きから再開します（$conditions）。"
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
