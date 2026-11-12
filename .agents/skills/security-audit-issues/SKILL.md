---
name: security-audit-issues
description: Cloudflare の security-audit でフル監査し、独立検証済みの所見から非公開リポジトリの修正 Issue を作成・更新する。
---

# フル監査の結果を GitHub Issue に反映する

監査するプロジェクトの直下で実行する。Cloudflare の `security-audit` でフル監査し、成果物は実行者の端末に保存する。監査対象の GitHub リポジトリの Issue を修正の共通台帳にする。

## 実行環境を確かめる

- Cloudflare の `skills/security-audit/` を、参照ファイル・スキーマ・バリデーターごと、信頼できるスキルの配置先（例 `~/.agents/skills/security-audit/`）に置く。監査には `git`・`node`・サブエージェントと、保存先への書き込み権限を使う。 [Cloudflare のスキル](https://github.com/cloudflare/security-audit-skill/tree/c1c8a8c1471069fb0e188eeaff69b8e8db6564a8/skills/security-audit)
- Issue の反映には、対象ホストでログイン済みの `gh` と Issue の作成・編集権限を使う。確認には [skills-preflight](../skills-preflight/SKILL.md) を使える。GitHub の前提を満たせない場合も、監査成果物は端末に保存する。

## 引数を確かめる

```text
$security-audit-issues [--profile quick|standard|deep]
```

- `--profile` の既定値は `standard`。指定があれば `quick`・`standard`・`deep` のいずれかを、そのまま元スキルに渡す。それ以外の値が指定された場合は使える値を案内し、監査を保留する。
- `git rev-parse --show-toplevel` で監査対象を確かめる。Git リポジトリを特定できない場合は、監査するプロジェクトの直下で実行するよう案内する。

## 監査して結果を反映する

1. 導入済みの `security-audit` の `SKILL.md` と対象に必要な参照ファイルを読む。監査前に [登録先の決め方](references/issue-sync.md#監査開始前に登録先を特定する) に従い、GitHub リポジトリを特定する。
2. 指定プロファイルで元スキルの手順と隔離条件に従ってフル監査し、結果を `~/security-audit-skill/<repo-name>/run-<N>/` に保存する。一部の作業が止まったら [監査の一部が止まった場合](#監査の一部が止まった場合) に従う。最終報告（未完了の監査の部分報告を含む）を確定した実際の UTC 日時を `date -u '+%Y-%m-%dT%H:%M:%SZ'` などで控える。
3. [Issue に反映する手順](references/issue-sync.md) に従い、同じ実行の成果物を照合する。独立検証済みの `confirmed` のうち、監査対象コミットを根拠とする所見を `gh` で反映する。反映対象には `agent:security-audit` を付け、人の判断を待たず修正・検証・PR 作成まで進められる Issue には `agent:autofix` も付ける。
4. 日本語で監査の完了状況・監査対象 SHA・確定（`confirmed`）／要検証（`needs_validation`）／未検証の件数を報告する。確かめられない件数は不明とする。`REPORT.md` を保存できたら絶対パスを示し、保存できなければ保存済み成果物の絶対パスと停止理由を示す。Issue の作成／更新／変更なし／保留の件数と該当する Issue の URL を報告し、`agent:autofix` を追加した Issue を示す。別名の追加・古い結果・再発候補・権限不足・追加検証や人の判断が必要な項目には理由を添える。

## 監査の一部が止まった場合

- 指定プロファイル・監査範囲・証拠基準を維持する。止まった項目とその依存作業を保留し、元スキルの工程順と前提を守って、独立して進められる作業を続ける。
- 一時エラーは安全に再試行できる場合に復旧する。Daybreak の案内や権限不足で拒否された操作は自動再試行を保留し、ソースや既存テストの読み取りなど、許可された方法で必要な事実を確かめられるか判断する。
- 初期調査から成果物の検証・保存まで、親エージェントが進捗を随時保存する。停止した工程・項目 ID（カバレッジ単位 ID や fingerprint など）・理由・確認済みの根拠・残作業・再開条件は、同じ実行の `coverage-ledger.json` に元スキルの形式を保って記録する。台帳に記録できない場合は `run-metadata.json` を使い、どちらにも保存できなければユーザーへの報告に含める。再開時は記録を読み直し、監査対象 SHA と再開条件を確認する。
- 最終版の `findings.json` には、元スキルが指定プロファイルで求める独立検証をすべて終えた判定結果を記録する。判定に至らなかった候補は台帳の `candidate` に未解決の理由を記録し、未検証として `needs_validation` と別に数える。
- 必須工程や監査範囲に停止による未完了が残る場合は、`run_status: "incomplete"` と `incomplete_reason` を実行メタデータに記録する。残った範囲と再開条件をユーザーに伝え、保存できる場合は部分報告にも記載する。
