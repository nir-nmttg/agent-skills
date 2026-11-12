---
name: security-audit-issues
description: Cloudflare の security-audit でフル監査し、独立検証済みの所見から非公開リポジトリの修正 Issue を作成・更新する。
---

# フル監査の結果を GitHub Issue に反映する

監査するプロジェクトの直下で実行する。Cloudflare の `security-audit` でフル監査し、成果物は実行者の端末に保存する。監査対象の GitHub リポジトリの Issue を修正の共通台帳にする。

## 引数を確かめる

```text
$security-audit-issues [--profile quick|standard|deep]
```

- `--profile` の既定値は `standard`。指定があれば `quick`・`standard`・`deep` のいずれかを、そのまま元スキルに渡す。それ以外の値が指定された場合は使える値を案内し、監査を保留する。
- `git rev-parse --show-toplevel` で監査対象を確かめる。Git リポジトリを特定できない場合は、監査するプロジェクトの直下で実行するよう案内する。

## 監査して結果を反映する

1. 導入済みの `security-audit` の `SKILL.md` と対象に必要な参照ファイルを読む。[登録先の決め方](references/issue-sync.md#監査開始前に登録先を特定する) に従って対象の GitHub リポジトリを特定し、元スキルのメタデータに記録する。一意に特定できない場合も監査は進め、Issue への反映は保留する。
2. 指定プロファイルで元スキルのフル監査を行い、結果を `~/security-audit-skill/<repo-name>/run-<N>/` に保存する。実行と隔離は元スキルに従う。最終報告を仕上げた時点で実際の完了日時を UTC で控える。再開時などで確かめられない日時は不明とする。
3. [Issue に反映する手順](references/issue-sync.md) に従い、同じ実行の成果物を照合する。独立検証済みの `confirmed` のうち、監査対象コミットを根拠とする所見だけを `gh` で反映する。反映対象に `agent:security-audit` を付け、人の判断を待たず修正・検証・PR 作成まで進められる Issue には `agent:autofix` も付ける。登録先に必要なラベルがなければ作成する。
4. 日本語で `REPORT.md` の絶対パス・監査対象 SHA・作成／更新／変更なし／保留の件数と Issue URL を報告する。`agent:autofix` を追加した Issue を示す。別名の追加・古い結果・再発候補・権限不足・追加検証や人の判断が必要な項目には理由を添える。
