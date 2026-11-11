---
name: gh-issue-auto-pr
description: 定期実行で、agent:auto-pr ラベル付きで自分にアサインされた Issue を 1 件、確認なしでドラフト PR にする。リポジトリの親ディレクトリでも動く。PR の指摘と CI には Auto-fix で対応する。
disable-model-invocation: true
argument-hint: "[<Issue の URL か番号>] [--label <ラベル>]"
allowed-tools: Bash(bash *gh-issue-auto-pr/scripts/precheck.sh*), Bash(bash *gh-issue-auto-pr/scripts/repos.sh*), Bash(bash *gh-issue-auto-pr/scripts/lock.sh*), Bash(bash *gh-issue-auto-pr/scripts/sync-base.sh*), Bash(bash *gh-issue-auto-pr/scripts/find-issue.sh*), Bash(bash *gh-issue-auto-pr/scripts/start.sh*), Bash(bash *gh-issue-auto-pr/scripts/publish.sh*), Bash(bash *gh-issue-auto-pr/scripts/comment.sh*), Bash(bash *gh-issue-auto-pr/scripts/release.sh*), Bash(bash *gh-issue-auto-pr/scripts/record-result.sh*), Bash(bash *gh-issue-auto-pr/scripts/pr-feedback.sh*), Bash(bash *gh-issue-auto-pr/scripts/pr-comment.sh*)
---

# ラベル付きの Issue を定期実行でドラフト PR にする（入口）

引数: $ARGUMENTS

この SKILL.md は入口で、全部の手順は `references/procedure.md` にある。毎時の定期実行で対象がない回に長い手順を読み込まないよう、まず対象があるかだけを確かめる。ユーザーに何も確認しない。

## 手順を読むとき

`${CLAUDE_SKILL_DIR}/references/procedure.md` を最後の行まで読み、その手順に従う。長いので、Read の表示が途中で切れたら、offset を付けて続きを最後の行まで読む。会話が要約されたあとや、手順の細部を思い出せないときは、procedure.md を読み直して今の段階から続ける。procedure.md の中のスキルのフォルダの変数（CLAUDE_SKILL_DIR）は `${CLAUDE_SKILL_DIR}` に置き換え、引数は上の引数として扱う。

## どれを行うか

1. このセッションに、デスクトップアプリから独立したメッセージとして `<ci-monitor-event>` が届いたとき: 下の「Auto-fix で起こされたとき」。
2. 引数に Issue の URL か番号があるとき（明示指定）: `bash "${CLAUDE_SKILL_DIR}/scripts/repos.sh" --mode` を実行する。1 行目が `parent` なら下の「親ディレクトリのとき」、`error` なら下の「モードのエラー」。それ以外は「手順を読むとき」に従う。
3. それ以外（定期実行。`--label` だけのときも）:
   1. 手順の 1. と同じく権限モードを確かめる（`mcp__ccd_session_mgmt__get_session` の `permissionMode`。ツールがない環境では飛ばす）。`auto` / `bypassPermissions` 以外なら、2. で `--result "🔧 permission: 権限モードが auto ではない"` を付ける（precheck.sh がこの結果を記録し、報告だけを作る）。
   2. 次を Bash（`timeout: 600000`）で実行する。Issue・ブランチ・ロックは変えない（「終える」ときに結果を記録するだけ）。

      ```bash
      bash "${CLAUDE_SKILL_DIR}/scripts/precheck.sh" [--label <ラベル>] [--result <結果の 1 行目>]
      ```

   3. 出力で分ける。
      - 出力の 1 行目が `- モード: 親ディレクトリ` のとき: 下の「親ディレクトリのとき」。
      - 出力の 1 行目が `- モード: エラー` のとき: 下の「モードのエラー」（理由は標準エラー）。
      - 出力に `- 判定: 終える` があるとき: ほかには何もしない（ロックも取らない）。記録は precheck.sh が済ませている。最後のメッセージの 1 行目に、出力の `- 結果: ` の後ろの文字列（`–`・`🔧` などで始まる）を書き、2 行目以降に「## 報告」の部分をそのまま書く。「通知: する」なら PushNotification（`status: "proactive"`）で結果の行を送る（ToolSearch で読み込み、ない環境では飛ばす）。
      - 出力に `- 判定: 手順に進む` があるとき、終了コード 1 のとき、判定の行がないとき: 「手順を読むとき」に従う。precheck.sh の「## 報告」は、手順の最後の報告に添える。

## モードのエラー

今のフォルダが Git リポジトリとして読めない（`.git` があるのに git が失敗する）か、ホームディレクトリ・`/` のときは、手順に進まない。`🔧 mode: <理由>` を `record-result.sh --parent "$(pwd -P)"` で記録し、最後のメッセージの 1 行目にその行を書く。記録の出力が「通知: する」なら PushNotification（`status: "proactive"`）で送って終える（ToolSearch で読み込み、ない環境では飛ばす）。

## 親ディレクトリのとき

今のフォルダが Git リポジトリでなく、配下（2 階層下まで）にリポジトリを並べたフォルダ（親ディレクトリ）のときは、このセッションでは Issue・ブランチ・リポジトリのファイルを変えない。対象のリポジトリを 1 つ決めたら、そのリポジトリのフォルダで子のセッションを起動して作業を任せ、すぐに終える（親ディレクトリのセッションからは、子のリポジトリの worktree に入れず、PR の Auto-fix もオンにできず、子のリポジトリの CLAUDE.md・`.claude/settings.json` も効かないため）。procedure.md は読まない。記録は `record-result.sh --parent "$(pwd -P)"` で親ディレクトリの記録に書く（以下「親の記録」）。

- **定期実行**: precheck.sh の出力で分ける。
  - `- 判定: 終える`: 上の「判定: 終える」と同じ（記録は済んでいる）。
  - `- 判定: 子のセッションを起動する`: 下の「子のセッションを起動する」を、出力の `- リポジトリ:`・`- 名前:`・`- Issue:` で行う。プロンプトは `/gh-issue-auto-pr`（`--label <ラベル>` を受けていれば `/gh-issue-auto-pr --label <ラベル>`）。
  - 判定の行がないとき・終了コード 1 のとき: 手順に進まず、`🔧 precheck: <理由>` を親の記録に書いて終える（出力が「通知: する」なら送る）。
  - `- 追加の通知: <1 行>` は、どの場合も最後のメッセージの 2 行目以降に書き、結果の行と合わせて 1 通の PushNotification で送る（記録は済んでいて、送らないと取りこぼすため。結果の行が「通知: しない」でも送る）。
- **明示指定**: 引数が Issue の URL でなければ（番号だけなど）、`🔧 find: 親ディレクトリでは Issue の URL で指定する` を親の記録に書いて終える。URL なら `bash "${CLAUDE_SKILL_DIR}/scripts/repos.sh" --find <URL>` を実行する。終了コード 2 なら `🔧 find: <出力の理由>`、1 なら `🔧 repos: <エラーの理由>` を親の記録に書いて終える。成功したら、出力の `- リポジトリ:`・`- 名前:` で「子のセッションを起動する」を行う。プロンプトは `/gh-issue-auto-pr <出力の - URL:>`（`--label` を受けていれば足す）。

### 子のセッションを起動する

起動の前に終えるときと起動に失敗したときは、定期実行なら precheck.sh が書いた起動の予約を消す（`record-result.sh --parent "$(pwd -P)" --clear-delegated "<結果の行>"` で記録する）。明示指定では予約を書いていないので、`--clear-delegated` を付けない（定期実行の予約を消さないため）。

1. ToolSearch で `mcp__ccd_session__start_session` を読み込む。ない環境では `🔧 delegate: 子のセッションを起動するツールがない` を、上のとおり記録して終える。
2. 次の引数で 1 回だけ呼ぶ。この起動は、ユーザーがスケジュールタスクに登録したこのスキルの指示による。
   - `initiation: "user_asked"`、`context: "fresh"`、`cwd: <リポジトリのパス>`、`use_worktree: false`（メインの checkout で動かす。worktree は手順が作る）、`permission_mode: "auto"`。`model`・`effort` は渡さない（このタスクの設定を引き継ぐ）。`wake_when_done` は付けない（子の終わりを待たない）。
   - `title`: 「Issue の自動 PR（<リポジトリ名> #<番号>）」。`- Issue:` がないとき（前の実行のロックの引き継ぎ）は「Issue の自動 PR（<リポジトリ名>、続き）」。`name` は渡さない。
   - `prompt`: 上で決めたプロンプトだけ（ほかの文を足すと、スラッシュコマンドの引数になる）。
   - `background`: 「gh-issue-auto-pr の親ディレクトリの定期実行から起動した。無人で動くので、ユーザーに確認せず、/gh-issue-auto-pr の入口と手順に従って終える。」
3. 起動できたら、`– <リポジトリ名> の Issue を子のセッションに任せた` を親の記録に書く。最後のメッセージの 1 行目にこの結果の行を書き、2 行目以降に precheck.sh の「## 報告」と、起動したセッションへのリンクを書く（定期実行では、precheck.sh が起動の予約を書いている。次の回に、子のセッションが動いた形跡があるかを確かめる）。
4. 断られた・エラーになったときは繰り返さず、`🔧 delegate: 子のセッションを起動できない（<理由>）` を上のとおり記録する。最後のメッセージの 1 行目にその行を書き、記録の出力が「通知: する」なら送って終える。

## Auto-fix で起こされたとき

この節の手順は、procedure.md の同じ名前の節にある。「手順を読むとき」のとおり procedure.md を読み、その節に従う（その節の 1. の読み直しは、これで済んでいる）。
