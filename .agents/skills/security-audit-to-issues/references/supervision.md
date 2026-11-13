# Supervisor として Coordinator の停止を見張る

Codex の安全審査は、詳細が集まる Coordinator のターンを途中で終わらせることがある（`cyber_policy`）。終わってもセッションは残り、「続けてください」と送れば続きから進む。このスキルを呼び出したエージェントを **Supervisor** にし、監査と Issue 反映を **Coordinator**（サブエージェント）に任せて、Coordinator が止まったら Supervisor が人の代わりに続きを頼む。

- Supervisor が読むのは、`scripts/supervise.mjs` が出す決まった語・数・ハッシュ・URL・保留の理由（Coordinator が `issue_sync` に記録した短い文）と、Coordinator の状態報告だけにする。Coordinator への指示は [1. 始める](#1-始める) の文面にする。
- Supervisor が書くのは、実行フォルダの `supervisor.json`（`scripts/supervise.mjs` 経由）だけ。元スキルの共有ファイルと `run-metadata.json` は Coordinator が書く。
- 停止のあとの続きは、人が手で送っていたのと同じ「続けてください。」で頼む。

以下、`SUPERVISE` はこのスキルのフォルダにある `scripts/supervise.mjs` を `node` で実行すること、`RUN_DIR` は実行フォルダの絶対パスを表す。

## 1. 始める

1. 同じ会話の中で扱っている実行があれば、`SUPERVISE state "$RUN_DIR"` で段階を読み、[4. Supervisor が再開したとき](#4-supervisor-が再開したとき) に進む。新しく呼び出されたときは、新しい実行を始める。
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
| ターンが終わり、最終回答が状態報告の JSON で、`run_dir` が `RUN_DIR` と同じ | 状態に従う（下記） |
| ターンが終わり、`run_dir` が `RUN_DIR` と違う | `SUPERVISE record "$RUN_DIR" run_dir_mismatch` を実行し、そのパスは使わずに [3. 続きを頼む](#3-続きを頼む) に進む（`report` になる） |
| ターンが終わり、最終回答が状態報告の形でない（文章など） | `SUPERVISE record "$RUN_DIR" malformed` を実行し、[3. 続きを頼む](#3-続きを頼む) に進む |
| ターンが終わり、最終回答がない（エラー・空） | 返り値にエラーの種別（例 `cyber_policy`）があれば、その語だけを付けて `SUPERVISE record "$RUN_DIR" stopped [<種別>]` を実行し、[3. 続きを頼む](#3-続きを頼む) に進む。エラーの文面は記録しない |
| 状態を確かめられない | `SUPERVISE record "$RUN_DIR" unknown` を実行し、[3. 続きを頼む](#3-続きを頼む) に進む（`wait` なら待ち直す） |

状態報告を受け取ったとき:

- `complete`・`incomplete`: `SUPERVISE check "$RUN_DIR" <status>` が `ok` なら `SUPERVISE finish "$RUN_DIR" done` を実行し、[5. 報告する](#5-報告する) に進む。`mismatch` なら `SUPERVISE record "$RUN_DIR" malformed` を実行してから [3. 続きを頼む](#3-続きを頼む) に進む（Issue 反映が残っていれば、Coordinator はそれを続ける）。
- `unsupported`: `SUPERVISE record "$RUN_DIR" unsupported` を実行し（段階が `self_auditing` になる）、Supervisor が同じ `RUN_DIR` を出力先にして SKILL.md の手順 1〜5 をいまの形で行う。終えたら `SUPERVISE finish "$RUN_DIR" done` を実行する。止まったら人が「続けてください」を送る。

## 3. 続きを頼む

`SUPERVISE next "$RUN_DIR"` の出力に従う。

- `continue`: 先に `SUPERVISE record "$RUN_DIR" resuming` を実行し（自動の続きの回数を増やす）、同じ Coordinator に `followup_task` で「続けてください。」とだけ送り、[2. 待つ・判定する](#2-待つ判定する) に戻る。最後の記録が `malformed`（状態報告の形でない、照合が合わない）のときは、状態報告の出し直しとして「SKILL.md の状態報告の JSON だけを最終回答にして、続けてください。」と送る。`followup_task` が失敗したら再試行せず、`SUPERVISE record "$RUN_DIR" followup_failed` を実行して、もう一度 `SUPERVISE next` に従う（`report` になる）。
- `give_up`: `SUPERVISE finish "$RUN_DIR" gave_up <出力の reason>` を実行し、[5. 報告する](#5-報告する) を行ってターンを終える。
- `report`: 審査以外のエラーや送信の失敗。`SUPERVISE record "$RUN_DIR" returned <出力の reason>` を実行し、[5. 報告する](#5-報告する) を行ってターンを終える。
- `wait`: 待ち直す。
- `none`: 段階が `auditing` ではない。`SUPERVISE state` で段階を確かめ、[4. Supervisor が再開したとき](#4-supervisor-が再開したとき) に従う。

`give_up` は、続けて2回進まなかった停止（実行フォルダの成果物のハッシュが前回の停止から変わらない）、自動の続きが上限の8回（`malformed` の出し直しを含む）に達したとき、状態不明が3回続いたときに出る。

## 4. Supervisor が再開したとき

Supervisor 自身が止まり、利用者の「続けてください」で再開したときは、同じ Coordinator と実行フォルダで続ける。`SUPERVISE state "$RUN_DIR"` の段階で分ける。

- `starting`: Coordinator の ID がなく、起動したかを確かめられない。利用者に返す。
- `auditing`: まず `SUPERVISE next "$RUN_DIR"` を実行する。`report` なら、利用者の「続けてください」を受けて `SUPERVISE record "$RUN_DIR" human_resume` を実行し、同じ Coordinator に続きを頼む。それ以外なら Coordinator の状態を `list_agents` などで確かめ、動いていれば待ちに戻る。終わっていて、その終わり方をまだ記録していなければ [2. 待つ・判定する](#2-待つ判定する) の表で判定する（直前の出来事が停止で、そのあと `resuming` を記録していなければ記録済みなので、記録し直さずに [3. 続きを頼む](#3-続きを頼む) に進む）。見つからなければ利用者に返す。
- `self_auditing`: Supervisor がいまの形で続ける。
- `gave_up`: 利用者が「続けてください」と送ったときだけ、`SUPERVISE resume "$RUN_DIR"`（段階を `auditing` に戻し、回数を数え直す）を実行し、同じ Coordinator に `followup_task` で「続けてください。」と送る。
- `done`: [5. 報告する](#5-報告する) を行う。

Supervisor 自身が止まって利用者の「続けてください」で再開した場合は、どの段階でも最初に `SUPERVISE record "$RUN_DIR" supervisor_resume` を実行してから上の手順に進む（Supervisor の再開の回数に入る。Coordinator への続きの依頼とは別の記録なので、記録済みの停止はそのまま判定に使われる）。

## 5. 報告する

自動で続けるのをやめるとき（`done`・`give_up`・`report`）は、どの場合も `SUPERVISE summary "$RUN_DIR"` の値で、SKILL.md の手順 5 の最終報告を書く。値が `null` の件数は不明と書き、`files` が `missing`・`unreadable` のファイルと `incomplete_reason` を停止理由として示す。あわせて、止まった回数（`supervisor.stops`）、自動の続き（`auto_resumes`）、人による Coordinator の再開（`human_resumes`）、Supervisor の再開（`supervisor_resumes`）の回数、観測したエラーの種別、あきらめた・利用者に返した理由（`gave_up_reasons`・`returned_reasons`）を書く。
