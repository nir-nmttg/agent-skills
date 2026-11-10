---
name: gh-issue-autofix
description: 定期実行で、agent:autofix ラベル付きで自分にアサインされた Issue を 1 件、確認なしで直してドラフト PR にする。止めたら Issue に理由を書く。PR の指摘と CI には Auto-fix で対応する。
disable-model-invocation: true
argument-hint: "[<Issue の URL か番号>] [--label <ラベル>]"
allowed-tools: Bash(bash *gh-issue-autofix/scripts/precheck.sh*), Bash(bash *gh-issue-autofix/scripts/lock.sh*), Bash(bash *gh-issue-autofix/scripts/sync-base.sh*), Bash(bash *gh-issue-autofix/scripts/find-issue.sh*), Bash(bash *gh-issue-autofix/scripts/start.sh*), Bash(bash *gh-issue-autofix/scripts/publish.sh*), Bash(bash *gh-issue-autofix/scripts/comment.sh*), Bash(bash *gh-issue-autofix/scripts/release.sh*), Bash(bash *gh-issue-autofix/scripts/record-result.sh*), Bash(bash *gh-issue-autofix/scripts/pr-feedback.sh*), Bash(bash *gh-issue-autofix/scripts/pr-comment.sh*)
---

# ラベル付きの Issue を定期実行で直す（入口）

引数: $ARGUMENTS

この SKILL.md は入口で、全部の手順は `references/procedure.md` にある。毎時の定期実行で対象がない回に長い手順を読み込まないよう、まず対象があるかだけを確かめる。ユーザーに何も確認しない。

## 手順を読むとき

`${CLAUDE_SKILL_DIR}/references/procedure.md` を最後の行まで読み、その手順に従う。長いので、Read の表示が途中で切れたら、offset を付けて続きを最後の行まで読む。会話が要約されたあとや、手順の細部を思い出せないときは、procedure.md を読み直して今の段階から続ける。procedure.md の中のスキルのフォルダの変数（CLAUDE_SKILL_DIR）は `${CLAUDE_SKILL_DIR}` に置き換え、引数は上の引数として扱う。

## どれを行うか

1. このセッションに、デスクトップアプリから独立したメッセージとして `<ci-monitor-event>` が届いたとき: 下の「Auto-fix で起こされたとき」。
2. 引数に Issue の URL か番号があるとき（明示指定）: 「手順を読むとき」に従う。
3. それ以外（定期実行。`--label` だけのときも）:
   1. 手順の 1. と同じく権限モードを確かめる（`mcp__ccd_session_mgmt__get_session` の `permissionMode`。ツールがない環境では飛ばす）。`auto` / `bypassPermissions` 以外なら、2. で `--result "🔧 permission: 権限モードが auto ではない"` を付ける（precheck.sh がこの結果を記録し、報告だけを作る）。
   2. 次を Bash（`timeout: 600000`）で実行する。Issue・ブランチ・ロックは変えない（「終える」ときに結果を記録するだけ）。

      ```bash
      bash "${CLAUDE_SKILL_DIR}/scripts/precheck.sh" [--label <ラベル>] [--result <結果の 1 行目>]
      ```

   3. 出力で分ける。
      - 出力に `- 判定: 終える` があるとき: ほかには何もしない（ロックも取らない）。記録は precheck.sh が済ませている。最後のメッセージの 1 行目に、出力の `- 結果: ` の後ろの文字列（`–`・`🔧` などで始まる）を書き、2 行目以降に「## 報告」の部分をそのまま書く。「通知: する」なら PushNotification（`status: "proactive"`）で結果の行を送る（ToolSearch で読み込み、ない環境では飛ばす）。
      - 出力に `- 判定: 手順に進む` があるとき、終了コード 1 のとき、判定の行がないとき: 「手順を読むとき」に従う。precheck.sh の「## 報告」は、手順の最後の報告に添える。

## Auto-fix で起こされたとき

この節の手順は、procedure.md の同じ名前の節にある。「手順を読むとき」のとおり procedure.md を読み、その節に従う（その節の 1. の読み直しは、これで済んでいる）。
