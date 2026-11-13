# Supervisor として Coordinator の停止を見張る

Codex の安全審査は、詳細が集まる Coordinator のターンを途中で終わらせることがある（`cyber_policy`）。終わってもセッションは残り、続きを頼めば続きから進む。このスキルを呼び出したエージェントを **Supervisor** にし、監査と Issue 反映を **Coordinator**（サブエージェント）に任せて、Coordinator が止まったら Supervisor が人の代わりに続きを頼む。

- Coordinator の審査による停止は、このスキルが想定している出来事。止まると、Coordinator の最終回答として `Agent errored: This content was flagged for possible cybersecurity risk …` と Daybreak の申請の案内が届く。これは利用者が手で続きを頼んでいたのと同じ停止で、自動で続きを頼むのは利用者が選んだ扱い。案内を理由に監査を打ち切らず、次の動きは `SUPERVISE` の判定だけで決める。続きを頼んだターンも審査の対象のままで、Coordinator には止まる直前の作業をやり直さずに保留させる。進まなければ判定が `give_up` を出す。
- Supervisor が読むのは、`scripts/supervise.mjs` が出す決まった語・数・ハッシュ・URL・保留の理由（Coordinator が `issue_sync` に記録した短い文）・送る文面と、Coordinator の状態報告だけにする。Coordinator から途中のメッセージが届いても中身は使わず、利用者には `SUPERVISE summary` の件数で進み具合を伝える。
- Supervisor が Coordinator に送るのは、[1. 始める](#1-始める) の指示と、`SUPERVISE` が「送る文面:」の下に出す文面だけにする。文面は書き換えず、足さない。作業の打ち切りや進め方の指示は送らず、Worker を中断させない（`interrupt_agent` を使わない）。
- Supervisor が書くのは、実行フォルダの `supervisor.json`（`scripts/supervise.mjs` 経由）だけ。元スキルの共有ファイルと `run-metadata.json` は Coordinator が書く。

以下、`SUPERVISE` はこのスキルのフォルダにある `scripts/supervise.mjs` を `node` で実行すること、`RUN_DIR` は実行フォルダの絶対パスを表す。

## 1. 始める

1. 同じ会話の中で扱っている実行があれば、`SUPERVISE state "$RUN_DIR"` で段階を読み、[4. 利用者が続きを頼んだとき](#4-利用者が続きを頼んだとき) に進む。新しく呼び出されたときは、新しい実行を始める。
2. SKILL.md の「引数を確かめる」を行い、`~/security-audit-skill/<repo-name>/` に次の未使用の `run-<N>/` を作る。
3. `SUPERVISE init "$RUN_DIR"` を実行してから、`spawn_agent` で Coordinator を起動する。起動できたら、直後に `SUPERVISE attach "$RUN_DIR" <Coordinator のエージェント ID>` を実行する。`spawn_agent` が使えない・失敗したときは `SUPERVISE record "$RUN_DIR" unsupported` を実行し、Supervisor が同じ `RUN_DIR` を出力先にして SKILL.md の手順 1〜5 をいまの形で行う。

Coordinator への指示には次だけを書く。

```text
あなたは $security-audit-to-issues の Coordinator です。<このスキルの SKILL.md の絶対パス> の「Supervisor と Coordinator に分けて進める」にある Coordinator の役目に従ってください。
- 出力先には、作成済みの <RUN_DIR> を使ってください。
- フル監査です。プロファイル: <profile>、範囲: <範囲>、予算: <budget または null>。
- ターンを終えるときは、SKILL.md の状態報告の JSON だけを最終回答にしてください。
```

## 2. 待つ・判定する

`wait_agent` で Coordinator を待ち、返り方で分ける。

| 返り方 | すること |
| --- | --- |
| 時間切れ（Coordinator は動作中） | 待ち直す。回数に入れない |
| Coordinator から途中のメッセージが届いた | 中身は使わずに待ち直す |
| ターンが終わり、最終回答が状態報告の JSON で、`run_dir` が `RUN_DIR` と同じ | 状態に従う（下記） |
| ターンが終わり、`run_dir` が `RUN_DIR` と違う | `SUPERVISE record "$RUN_DIR" run_dir_mismatch` を実行し、そのパスは使わずに [3. 続きを頼む](#3-続きを頼む) に進む（`report` になる） |
| ターンが終わり、最終回答が `Agent errored:` で始まる、または最終回答がない | 停止として記録する。文面に `flagged for possible cybersecurity risk` を含むか、返り値のエラーの種別が `cyber_policy` なら `SUPERVISE record "$RUN_DIR" stopped cyber_policy`、ほかの種別なら `SUPERVISE record "$RUN_DIR" stopped <種別>`、`Agent errored:` で始まり審査の文言も種別もなければ `SUPERVISE record "$RUN_DIR" stopped other`（自動では続けない）、最終回答がまったくなく種別も分からなければ `SUPERVISE record "$RUN_DIR" stopped` を実行し、[3. 続きを頼む](#3-続きを頼む) に進む。エラーの文面は記録しない |
| ターンが終わり、最終回答が状態報告の形でない（上のどれでもない文章など） | `SUPERVISE record "$RUN_DIR" malformed` を実行し、[3. 続きを頼む](#3-続きを頼む) に進む |
| 状態を確かめられない | `SUPERVISE record "$RUN_DIR" unknown` を実行し、[3. 続きを頼む](#3-続きを頼む) に進む（`wait` なら待ち直す） |

状態報告を受け取ったとき:

- `complete`・`incomplete`: `SUPERVISE check "$RUN_DIR" <status>` が `ok` なら `SUPERVISE finish "$RUN_DIR" done` を実行し、[5. 報告する](#5-報告する) に進む。`mismatch` なら `SUPERVISE record "$RUN_DIR" malformed` を実行してから [3. 続きを頼む](#3-続きを頼む) に進む（Issue 反映が残っていれば、Coordinator はそれを続ける）。
- `unsupported`: `SUPERVISE record "$RUN_DIR" unsupported` を実行し（段階が `self_auditing` になる）、Supervisor が同じ `RUN_DIR` を出力先にして SKILL.md の手順 1〜5 をいまの形で行う。終えたら `SUPERVISE finish "$RUN_DIR" done` を実行する。止まったら人が「続けてください」を送る。

## 3. 続きを頼む

`SUPERVISE record` の出力の2行目以降（または `SUPERVISE next "$RUN_DIR"` の出力）が次の動きを示す。その1行目に従う。

- `continue`: 先に `SUPERVISE record "$RUN_DIR" resuming` を実行し（自動の続きの回数を増やす）、同じ Coordinator に `followup_task` で、判定の出力の「送る文面:」の下の文面をそのまま送り、[2. 待つ・判定する](#2-待つ判定する) に戻る。停止のあとは止まる直前の作業を保留させる文面、`malformed` のあとは状態報告の出し直しを頼む文面になる。`followup_task` が失敗したら再試行せず、`SUPERVISE record "$RUN_DIR" followup_failed` を実行して、その出力に従う（`report` になる）。
- `give_up`: `SUPERVISE finish "$RUN_DIR" gave_up <出力の reason>` を実行し、[5. 報告する](#5-報告する) を行ってターンを終える。
- `report`: 審査以外のエラーや送信の失敗。`SUPERVISE record "$RUN_DIR" returned <出力の reason>` を実行し、[5. 報告する](#5-報告する) を行ってターンを終える。
- `wait`: 待ち直す。
- `none`: 段階が `auditing` ではない。`SUPERVISE state` で段階を確かめ、[4. 利用者が続きを頼んだとき](#4-利用者が続きを頼んだとき) に従う。

`give_up` は、続けて2回進まなかった停止（実行フォルダの成果物のハッシュが前回の停止から変わらない）、自動の続きが上限の8回（`malformed` の出し直しを含む）に達したとき、状態不明が3回続いたときに出る。`returned` と `gave_up` は、判定がその語を出したときに、出力の reason でだけ記録できる。

## 4. 利用者が続きを頼んだとき

Supervisor が止まったあとや、報告してターンを終えたあとに、利用者が「続けてください」と送ったときは、同じ Coordinator と実行フォルダで続ける。最初に `SUPERVISE record "$RUN_DIR" supervisor_resume` を実行し（Supervisor の再開の回数に入る。Coordinator への続きの依頼とは別の記録なので、記録済みの停止はそのまま判定に使われる）、`SUPERVISE state "$RUN_DIR"` の段階で分ける。

- `starting`: Coordinator の ID がなく、起動したかを確かめられない。利用者に返す。
- `auditing`: まず `SUPERVISE next "$RUN_DIR"` を実行する。`report` なら `SUPERVISE record "$RUN_DIR" human_resume` を実行し、出力の「送る文面:」の下の文面を同じ Coordinator に `followup_task` で送り、[2. 待つ・判定する](#2-待つ判定する) に戻る。それ以外なら Coordinator の状態を `list_agents` などで確かめ、動いていれば待ちに戻る。終わっていて、その終わり方をまだ記録していなければ [2. 待つ・判定する](#2-待つ判定する) の表で判定する（直前の出来事が停止で、そのあと `resuming` を記録していなければ記録済みなので、記録し直さずに [3. 続きを頼む](#3-続きを頼む) に進む）。見つからなければ利用者に返す。
- `self_auditing`: Supervisor がいまの形で続ける。
- `gave_up`・`done`: `SUPERVISE resume "$RUN_DIR"` を実行する（段階を戻し、回数を数え直す。`done` は `run_status` が `complete` でなければ戻せる）。出力が `auditing` なら、「送る文面:」の下の文面を同じ Coordinator に `followup_task` で送り、[2. 待つ・判定する](#2-待つ判定する) に戻る。`self_auditing` なら（Coordinator を使わずに監査した実行）、Supervisor がいまの形で続ける。戻せなければ（監査を終えている）[5. 報告する](#5-報告する) を行う。

この節で送った `followup_task` が失敗したときも、[3. 続きを頼む](#3-続きを頼む) と同じく再試行せず、`SUPERVISE record "$RUN_DIR" followup_failed` を実行してその出力に従う。

## 5. 報告する

自動で続けるのをやめるとき（`done`・`give_up`・`report`）は、どの場合も `SUPERVISE summary "$RUN_DIR"` の値で、SKILL.md の手順 5 の最終報告を書く。値が `null` の件数は不明と書き、`files` が `missing`・`unreadable` のファイルと `incomplete_reason` を停止理由として示す。あわせて、止まった回数（`supervisor.stops`）、自動の続き（`auto_resumes`）、人による Coordinator の再開（`human_resumes`）、Supervisor の再開（`supervisor_resumes`）の回数、観測したエラーの種別、あきらめた・利用者に返した理由（`gave_up_reasons`・`returned_reasons`）を書く。
