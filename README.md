# agent-skills

普段の仕事で使う汎用的な Claude Code・Codex スキル集。Claude Code 用は `.claude/skills/`、Codex 用は `.agents/skills/` で管理する。

スキルの作成・変更ルールは [AGENTS.md](AGENTS.md) にまとめている。

## Codex 用スキル

Codex 用スキルは、`$スキル名` などでスキルを明示的に指定したときだけ使う。通常の依頼から Codex が自動で選ぶことはない。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [docs-sync](.agents/skills/docs-sync/SKILL.md) | README.md などを現状の実装を正として更新する。有用な説明と重要な制約を残し、古い説明・重複・不足を整理して、現在の使い方を見つけやすくする | `$docs-sync README.md を現状の実装に合わせて更新して`<br>`$docs-sync docs/usage.md を必要な情報に絞って整理して` | 対象のドキュメントと実装を参照できること |
| [project-design-refactor](.agents/skills/project-design-refactor/SKILL.md) | プロジェクトを探索し、設計文書と既存コードを根拠に、設計思想・責務分担・依存関係から逸脱した実装を見つけてリファクタリングする。意図的な例外を尊重し、既存の振る舞いを保って変更・検証する | `$project-design-refactor`<br>`$project-design-refactor src/billing をプロジェクトの設計に合わせてリファクタリングして` | 対象の設計・実装を参照でき、関連する検証を実行できること |
| [test-code-refine](.agents/skills/test-code-refine/SKILL.md) | テストが検出する不具合と守る振る舞いを確かめ、無駄なテストを削除・統合し、実装に依存するテストを本質的な振る舞いの確認へ書き換える。境界値・異常系・過去の不具合・重要な副作用の検出力を保ち、変更後に影響範囲を実行して確かめる | `$test-code-refine src/billing のテストを整理して`<br>`$test-code-refine この差分のテストを本質的なものにして` | 対象リポジトリのテスト実行環境 |

## Claude Code 用スキル一覧

スキルは呼び出し方で 3 種類に分かれる。初めて使うときは `/skills-preflight` で、必要なコマンドやログインがそろっているかを確認する。

| 種類 | 呼び出し方 | スキル |
| --- | --- | --- |
| [自動で使われる](#自動で使われるスキル) | 頼まなくても、条件に当たると Claude が自分の判断で使う。`/スキル名` や話しかけても使える | japanese-report・codex-design-review・codex-impl-review・opus-final-review・codex-impl・codex-test・session-status-emoji |
| [使う前に確認される](#使う前に確認されるスキル) | Claude が自分の判断では実行せず、条件に当たると「使いますか」と聞く。`/スキル名` や話しかけても使える | codex-risk-design-review・codex-risk-impl-review |
| [明示的に呼び出す](#明示的に呼び出すスキル) | `/スキル名` でしか動かない。話しかけても、Claude が自分の判断で使うこともない | skills-preflight・gh-todo・gh-issue-overview・gh-pr-precheck・codex-verify-prompt・browser-readonly-research・whats-next |

### 自動で使われるスキル

「自動で使う条件」に当たると、頼まなくても Claude が使う。`/スキル名` か「使い方の例」のように話しかけて、明示的に使うこともできる。

| スキル | できること | 自動で使う条件 | 使い方の例 | 前提 |
| --- | --- | --- | --- | --- |
| [japanese-report](.claude/skills/japanese-report/SKILL.md) | ユーザーへの報告（完了報告・調査結果・レビュー結果・質問や確認）を、見出しやラベルまで含めて自然な日本語で書く。英語で返ってきたサブエージェントや Codex の出力、英語のログも貼らずに日本語で要約する。コードの識別子・パス・コマンド・エラーの原文・一般的な技術用語は英語のまま残す。コミットメッセージや PR 本文などファイルに残すものはリポジトリの慣習に従う。`/japanese-report` で直前の報告を日本語に書き直す | Claude が結果を報告する前（とくに英語の材料をもとに書くとき） | `/japanese-report`<br>「さっきの報告を日本語で書き直して」<br>「日本語で報告して」 | なし |
| [codex-design-review](.claude/skills/codex-design-review/SKILL.md) | Claude が考えた設計を Codex CLI の GPT-6.1 Sol にセカンドオピニオンとしてレビューさせる。推論レベルは今の Claude と同じ（high なら high）、`--fast` で Fast モード。Codex は読み取り専用で既存コードと照らし合わせ、Claude が指摘ごとに採用・不採用を判断して設計の修正案を出す（`artifacts/codex-design-review/` に保存）。`--focus requirements,security` のように観点（requirements / reliability / security / simplicity）を指定すると、観点ごとに分けて Sol を並列に動かす | 3 ファイル以上・新しい機能や API・複数案から選んだ設計や、DB・公開 API・認証・課金などに触れる設計を提示する前（迷ったら使う。1〜2 ファイルの局所的な変更は除く）。基本は Sol 1 本で、新しいモジュールを 2 つ以上作るか 10 ファイル以上に手を入れる設計、DB・認証・課金などの高リスク領域に 2 つ以上触れる設計のときだけ、観点ごとに 2〜3 本並列にする | `/codex-design-review`<br>`/codex-design-review --focus requirements,reliability docs/design.md`<br>「この設計を Codex にレビューしてもらって」 | `codex` にログイン済み、`jq` |
| [codex-impl-review](.claude/skills/codex-impl-review/SKILL.md) | Claude が実装した変更（git の差分）を Codex CLI の GPT-6.1 Sol にコードレビューさせる。推論レベルは今の Claude と同じ（high なら high）、`--fast` で Fast モード。範囲は既定ブランチからの変更（未コミットを含む）が既定で、`--base` / `--commit` / `--uncommitted` で選べる。Codex は読み取り専用で差分と周辺コードを読み、Claude が指摘ごとに採用・不採用を判断し、自分が実装した変更なら採用した指摘を直す（`artifacts/codex-impl-review/` に保存）。`--focus correctness,security` のように観点（correctness / reliability / security / maintainability）を指定すると、観点ごとに分けて Sol を並列に動かす | 2 ファイル以上か 30 行以上のロジック変更や、DB・公開 API・認証・課金などに触れる変更を終えたら、完了報告やコミットの前（迷ったら使う。数行の変更やドキュメントだけの変更は除く）。基本は Sol 1 本で、15 ファイル以上か 500 行以上の変更、DB・認証・課金などの高リスク領域に 2 つ以上触れる変更のときだけ、観点ごとに 2〜3 本並列にする（この 2 つでは仕上げに opus-final-review も使う） | `/codex-impl-review`<br>`/codex-impl-review --fast --uncommitted`<br>「観点ごとに分けて Codex で並列に実装レビューして」 | `codex` にログイン済み、`jq`、対象が git リポジトリ |
| [opus-final-review](.claude/skills/opus-final-review/SKILL.md) | 実装の仕上げとして、この会話を共有しない別の Claude（Opus 5.5）に、要件と git の差分だけを渡して最終レビューさせる。実装者の説明を渡さないので、思い込みなしに「要件を満たしているか（要件ごとに判定）、抜けや要件にない変更はないか、バグはないか」を見てもらえる。推論レベルは今の Claude と同じ（high なら high）。範囲の選び方は codex-impl-review と同じ。Opus は `claude -p` の別セッションで、設定ファイル・MCP・スキルを読み込まず、ファイルの読み取りと読み取り専用の git コマンドだけで動く。Claude が指摘ごとに採用・不採用を判断し、自分が実装した変更なら採用した指摘を直す（`artifacts/opus-final-review/` に保存） | 15 ファイル以上か 500 行以上の変更、または DB・認証・課金などの高リスク領域に 2 つ以上触れる変更で、codex-impl-review などの指摘を直し終えたあとの最後の確認（Claude の使用量になるので、迷ったら使わない） | `/opus-final-review`<br>`/opus-final-review --uncommitted`<br>「仕上げにコンテキストなしの Opus で最終レビューして」 | `claude` にログイン済み、`jq`、対象が git リポジトリ |
| [codex-impl](.claude/skills/codex-impl/SKILL.md) | 実装を Codex CLI の GPT-6 Luna（推論レベル max・Fast モード固定）に任せ、Claude は分割・指示書づくり・レビューだけを行って Claude のトークンを節約する。ほぼ無料の Luna を活かすため、実装を独立した小タスクに分けて複数の Luna を git worktree で並行して動かし、その間 Claude は Luna に向かない部分を作業フォルダで進める。Codex はサンドボックス（ネットワークなし）で実装し、Claude が差分をレビューして作業フォルダに 3-way マージで反映、テストを実行し、小さな問題は自分で直し、大きな問題は Codex に差し戻す。コミットはしない（`artifacts/codex-impl/` に保存） | 要件と完了の条件がはっきりした 100 行以上の部分（既存パターンに沿った機能追加、テスト追加など）に取りかかるとき（100 行以上なら迷ったら任せる。100 行未満は Claude が書く） | `/codex-impl CSV エクスポートを追加して`<br>「この Issue の実装を Luna に並列で任せて」<br>「トークン節約で Codex に実装させてレビューして」 | `codex` にログイン済み、`jq`、対象が git リポジトリ |
| [codex-test](.claude/skills/codex-test/SKILL.md) | テスト・型チェック・リンターの実行を Codex CLI の GPT-6 Luna（推論レベル max・通常速度固定）に任せ、失敗の要点・場所（`path:line`）・原因の見立てだけを報告させて、テストログを Claude が読むトークンを節約する。Codex はファイルを変更せず実行と切り分けだけを行い（変更があればスクリプトが警告）、Claude が報告をもとに直す。直したあとは `--resume` で同じスレッドに失敗したテストだけを再実行させられる。サンドボックスは既定でネットワークなし、`--network` で許可（`artifacts/codex-test/` に保存） | Claude がテスト・型チェック・リンター・ビルドを実行するときは原則すべて。実装の確認、完了報告・コミット・PR の前、失敗の切り分けでは必ず任せる（迷ったら任せる。数行で済む 1〜数件のテストを編集のたびに細かく繰り返している最中だけは Claude が直接実行する） | `/codex-test`<br>`/codex-test npm test と型チェックを実行`<br>「テストして」 | `codex` にログイン済み、`jq` |
| [session-status-emoji](.claude/skills/session-status-emoji/SKILL.md) | 並行して動かしているセッションの状態がサイドバーでひと目でわかるように、作業の段階に応じてこのセッション名の先頭に「絵文字 ｜タイトル」の形で絵文字を付ける（📝 計画中・🔍 調査・設計中・🛠️ 実装中・🧪 テスト・レビュー中・❓ 判断待ち・⏳ 外部待ち・🚀 PR 作成済み・🔥 ブロック・失敗・🎉 完了）。セッションを始めたときは、初期値として ✨ を付け、作業の段階が決まったら状態の絵文字に置き換える。どれにも当てはまらない状態には、合う絵文字を Claude が選ぶ。段階が変わったときとターンの終わりにだけ更新し、名前を変えたことは報告しない。変えるのはこのセッションの名前だけで、変更を断られたらそのセッションでは以後変えない | Claude デスクトップアプリでは、短い質問への回答も含めてすべてのセッションの最初のターン（以後、段階が変わるたびとターンの終わりに更新する。迷ったら使う） | `/session-status-emoji`<br>「セッション名に状態の絵文字を付けて」 | Claude デスクトップアプリ（Code タブ） |

### 使う前に確認されるスキル

重いので Claude が自分の判断で実行することはなく、「確認される条件」に当たると「使いますか」と聞いてから使う。`/スキル名` か「使い方の例」のように話しかけて、明示的に使うこともできる。

| スキル | できること | 確認される条件 | 使い方の例 | 前提 |
| --- | --- | --- | --- | --- |
| [codex-risk-design-review](.claude/skills/codex-risk-design-review/SKILL.md) | リスクの高い設計を、実装に入る前に Codex CLI の GPT-6 Astra に「どう壊れるか」の観点でレビューさせる。後から戻しにくい判断、データの破損・消失、セキュリティ、並行処理、課金や外部への副作用、移行とリリースの手順を重点的に見る。推論レベルは今の Claude と同じ（high なら high）、`--fast` で Fast モード。設計書のまとめ方と、Claude が指摘を判断して修正案を出す流れは codex-design-review と同じ（`artifacts/codex-risk-design-review/` に保存） | DB 移行・認可・課金・外部への送信など、壊れると影響が大きく戻しにくい設計を提示・実装する前 | `/codex-risk-design-review`<br>`/codex-risk-design-review --fast docs/design.md`<br>「実装前にこの設計を Astra でレビューして」 | `codex` にログイン済み（Astra が使えるプラン）、`jq`、codex-design-review スキル（スクリプトを共有） |
| [codex-risk-impl-review](.claude/skills/codex-risk-impl-review/SKILL.md) | リスクの高い実装（git の差分）を Codex CLI の GPT-6 Astra に「どう壊れるか」の観点でレビューさせる。データの破損・消失、セキュリティ、並行処理、課金や外部への副作用、移行と互換性、失敗時の動きを重点的に見る。推論レベルは今の Claude と同じ（high なら high）、`--fast` で Fast モード。範囲の選び方と、Claude が指摘を判断して直す流れは codex-impl-review と同じ（`artifacts/codex-risk-impl-review/` に保存） | DB 移行・認可・課金・外部への送信など、壊れると影響が大きく戻しにくい変更の完了報告やコミットの前 | `/codex-risk-impl-review`<br>`/codex-risk-impl-review --fast --uncommitted`<br>「本番に出す前に Astra でレビューして」 | `codex` にログイン済み（Astra が使えるプラン）、`jq`、対象が git リポジトリ、codex-impl-review スキル（スクリプトを共有） |

### 明示的に呼び出すスキル

`/スキル名` でしか動かない。話しかけても、Claude が自分の判断で使うこともない。

| スキル | できること | 使い方の例 | 前提 |
| --- | --- | --- | --- |
| [skills-preflight](.claude/skills/skills-preflight/SKILL.md) | このリポジトリのスキルを使うのに必要なもの（`git`・`jq`・`codex`・`claude`・`gh`・`python3`・`curl` のコマンドと、Codex・Claude・gh のログイン）がそろっているかを確認し、スキルごとに使える / 使えないをまとめる。足りないものはインストール・ログインの方法（Homebrew 前提）を案内する。`~/.claude/skills` へのリンクの有無も確認する。何もインストール・変更しない | `/skills-preflight` | なし |
| [gh-todo](.claude/skills/gh-todo/SKILL.md) | レビュー依頼されている PR、直近のメンションで未返信のもの、自分にアサインされている open な Issue / PR を組織ごとの表で一覧化する | `/gh-todo`<br>`/gh-todo レビュー依頼とメンションだけ` | `gh` にログイン済み |
| [gh-issue-overview](.claude/skills/gh-issue-overview/SKILL.md) | Issue を調べ、「なにをどうするか」がひと目でわかる実装計画の概要（前提・5W1H・全体像の図・進め方）を組み込みブラウザに表示する（`artifacts/gh-issue-overview/` に保存）。細かい実装には触れない | `/gh-issue-overview <Issue の URL>`<br>`/gh-issue-overview <Issue の URL> バックエンドだけ` | `gh` にログイン済み、`python3` |
| [gh-pr-precheck](.claude/skills/gh-pr-precheck/SKILL.md) | PR を人間のレビューに出す前の最終確認。Issue の本文・コメント・関連 Issue / PR・リンク先の資料・画像から要件を洗い出し、PR が要件を満たしているか（要件ごとに判定）、要件にない変更をしていないか、プロジェクトの方針（CLAUDE.md・CONTRIBUTING・PR テンプレート・既存コードの書き方）に沿っているか、CI・コンフリクト・Issue との紐づけ・未解決のレビューなどレビューに出せる状態かを確かめ、「進めてよい / 直してから / 確認が必要」を判定する（`artifacts/gh-pr-precheck/` に保存）。PR を省略すると、今のブランチの PR か Issue に紐づく PR を探す。コードの変更や GitHub への書き込みはしない | `/gh-pr-precheck <Issue の URL>`<br>`/gh-pr-precheck <Issue の URL> <PR の URL>` | `gh` にログイン済み、`jq`、`curl`、gh-issue-overview スキル（スクリプトを共有） |
| [codex-verify-prompt](.claude/skills/codex-verify-prompt/SKILL.md) | 変更が意図どおりに動くかを Codex に実際に動かして確かめてもらうための、そのまま貼れる依頼プロンプトを作る。PR を渡すと PR とそれが閉じる Issue から、省略するとこのセッションの会話と作業中の変更（未コミットを含む）から、確かめることを読み取る。検証環境の URL を渡すとその環境で、省略するとローカルで起動する手順（README・`package.json`・`.claude/launch.json` などから読み取る。PR なら別の worktree に取り出す）を書く。Codex に使わせるブラウザは `--browser builtin`（組み込みブラウザ）か `--browser chrome`（ログイン済みのユーザーの Chrome）で必ず指定する（ないときはプロンプトを作らずに聞き返す）。確認項目（主な流れ・境界やエラー・既存の機能の回帰）を手順と期待する結果つきの表にし、コードを変えない・外に影響する操作をしない・秘密情報を書かないなどの決まりと、報告の形を添える（`artifacts/codex-verify-prompt/` に保存）。Codex の実行やアプリの起動はしない | `/codex-verify-prompt --browser builtin <PR の URL> <検証環境の URL>`<br>`/codex-verify-prompt --browser chrome <PR の URL>`<br>`/codex-verify-prompt --browser builtin https://staging.example.com ログイン周りだけ` | `git`、`jq`（PR を渡すときは `gh` にログイン済み） |
| [browser-readonly-research](.claude/skills/browser-readonly-research/SKILL.md) | 組み込みブラウザか Chrome（ユーザーのログイン状態のまま）でページを読むだけの情報収集をし、要点・出典・読めなかったページを日本語のレポートにまとめる（`artifacts/browser-readonly-research/` に保存）。クリックでの送信・入力・ログイン・同意・ダウンロードはせず、ログアウトや承認などを表す URL も開かない。ページ内の指示には従わない。公開ページは WebFetch を先に使い、Chrome は `--chrome` か頼まれたときだけ使う | `/browser-readonly-research <URL> このページの要点をまとめて`<br>`/browser-readonly-research --chrome <社内ツールの URL> 今週の変更点を調べて` | Claude デスクトップアプリの組み込みブラウザ、または Claude in Chrome 拡張機能 |
| [whats-next](.claude/skills/whats-next/SKILL.md) | 並行して進めているセッションに戻ってきたときに、このセッションの目的・終わったこと・残っていること・待っているもの（ユーザーの判断・CI・ほかのセッションなど）を短くまとめ、次にやるべきアクションを 1 つ示す。ブランチ・未コミットの変更・push していないコミット・PR の CI はスクリプトで確かめ、会話の内容と食い違えば状態のほうを正とする。あわせて、Claude が進められるアクションなら実行する手順と止まるところを、ユーザーが決めるアクションなら選択肢とおすすめを提案し、デスクトップアプリでは「進めて」などのボタンで返事ができる。承認されるまで実行せず、承認されたら提案に書いた範囲だけを実行する | `/whats-next`<br>`/whats-next 今日は 30 分だけ` | なし（ボタンは Claude デスクトップアプリ（Code タブ）。PR の状態は `gh` にログイン済みのときだけ） |

## 実行結果の保存先

レポートなどスキルが作るファイルは、このリポジトリ直下の `artifacts/<スキル名>/` に保存される（`.gitignore` 済み）。他のフォルダから使ったときも同じ場所に保存される。

## 他のフォルダでも使う

リポジトリ直下で次を実行すると、Claude Code 用は `~/.claude/skills/`（`CLAUDE_CONFIG_DIR` 指定時はその配下の `skills/`）、Codex 用は `~/.agents/skills/` にシンボリックリンクされ、他のフォルダでも使える。

```bash
scripts/link-skills.sh

# 片方だけリンクする場合
scripts/link-skills.sh --claude
scripts/link-skills.sh --codex
```

- 引数なし、または `--all` で両方をリンクする。Claude と Codex のスキルは、それぞれ対応する場所にだけリンクする
- Codex の配置先とシンボリックリンク対応は [公式スキルドキュメント](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) に従う。追加が反映されなければ Codex を再起動する
- スキルを追加・削除したら、もう一度実行する（新しいスキルはリンクされ、削除したスキルの切れたリンクは消える）
- リポジトリを移したら、新しい場所でもう一度実行する（古い場所を指して切れたリンクは張り直される）
- 同名のスキルが別の場所にあるときは上書きせず、警告だけ出す
- git worktree（`.claude/worktrees/` など）からではなく、元のフォルダで実行する（worktree から実行すると、何もせずに元のフォルダでの実行を案内する）

## ライセンス

[MIT License](LICENSE)
