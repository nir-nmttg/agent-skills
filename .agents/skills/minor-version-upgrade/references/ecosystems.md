# Ruby・Node・Pythonの更新方法

両スキルで使う手引き。対象プロジェクトに存在する3言語の構成を調べ、該当する節だけを読む。NodeにはJavaScript／TypeScriptを含む。他言語は連携・依存境界を記録し、このスキルの更新対象へ広げない。

[静的ゲート](gate.md) の6レビューと公開7日待機を通して manifest・lockfile・環境指定・移行ソースを反映する。以下の導入・ビルド・テストは利用可能な場合の [追加検証](isolation.md#追加検証) として行う。lockfile-only・dry-run という名前だけで非実行と判断せず、コード評価がある解決・取得・生成は最初からレビュー済み隔離を使う。実行不能で正しい候補自体を作れない対象は保留し、完成した候補の追加テストだけが実行できない場合とは区別する。

## 管理方法と現在の版を特定する

| 系統 | 静的に読む主な指定 |
| --- | --- |
| Ruby | `Gemfile`、gemspec、`Gemfile.lock`、`.ruby-version`、`.bundle/config`、CI・コンテナ |
| Node | `package.json` の engines／`packageManager`、npm/pnpm/Yarn の lockfile、workspace、registry・hook設定、`.node-version`／`.nvmrc`、CI・コンテナ |
| Python | `pyproject.toml`、requirements／constraints、採用中の `uv.lock`／`poetry.lock`／`pylock.toml`／`Pipfile.lock`、`setup.py`／`setup.cfg`、`.python-version`、CI・コンテナ |
| 共通 | `.tool-versions`／`mise.toml` 等、既存のランタイム管理方法、private registry・mirror、Git／ローカル依存、ビルド・テスト設定 |

- Bundler、npm／pnpm／Yarn、uv／pip／Poetry等のうち採用済みの方式を使う。全ツールを導入する必要はない。別の管理ツール・Ruby/Python実装・vendor・lock方式へ勝手に切り替えない。グローバル環境は依頼された範囲だけ扱う。
- サブプロジェクトごとにmanifestとlockfileの対応を調べる。同じNodeプロジェクトに複数方式のlockfileがあれば、CI・`packageManager`・workspaceから正規の方式を特定し、不明なら保留する。別サブプロジェクトのlockfileを不要と判断して削除しない。
- 指定版と実際に選択される版を区別する。Corepack・uv・ランタイム管理ツール等に自動取得がある場合は、版確認の前に動作を調べ、正確な版・配布物を確認する。実行工程は検査済みcacheを使い再取得を防ぐ。対応する抑止方法は導入版の公式資料で確かめる。
- registry・scope・source/index・認証の適用先を静的に読み、各依存の取得元を旧版と比較する。新しい公開元やprivate/publicの切替を無条件に受け入れない。秘密値を出力しない。

## 一括更新と個別移行を分ける

| 更新対象 | 一括更新の候補 | 個別移行で扱う変更 |
| --- | --- | --- |
| Ruby本体 | 同一 `X.Y` のpatch | `X.Y` ブランチ変更、major変更 |
| Node本体 | 同一major内のminor・patch | major変更、同梱ツール等の非互換変更 |
| CPython本体 | 同一 `X.Y` のpatch | feature release／`X.Y` 系列変更、major変更 |
| gem・JS/TS package・Python package | 各製品が互換とするminor・patch | major、`0.x` のminor増加、非互換変更、互換性が不明な版 |

候補は公式のサポート方針・変更点・対象OS/archでも確認する。候補版と全新規配布物の最新公開から7日以上を必須とし、最新安定版が7日未満なら経過済みの適切な安定版を選ぶ。なければ保留して再開可能日または不明の理由を報告する。PythonのPEP 440はSemVerの保証ではない。CalVer・epoch・独自形式は公開元の方針で分類し、上表の数字だけで安全としない。Ruby/Pythonの別実装を使う場合も、その実装の公式方針を確認する。未確認候補は導入せず保留する。

ABI 別 wheel 等の同版配布物へ切り替える場合は、版上昇と分け、実配布物を識別する正確な `source` の変更として候補に記録し、新旧配布物の差分・hash・公開日・出所・監査・互換性をすべて確認する。minor では同版・同じ取得元の metadata だけの変更を拒否する。互換性不明なら一括更新に含めず個別移行へ回し、major では一件の移行境界と互換性を精査する。

## Ruby・Bundler

- Rubyの公式配布物をrelease記事のchecksumと照合する。Ruby指定、`Gemfile` のruby条件、`RUBY VERSION`、`BUNDLED WITH`、Rails等の要求範囲を突き合わせる。標準添付／bundled gem、OpenSSL、native extension、lockfileのplatformも確認する。
- Gemfile/gemspec・pluginsはRubyコードのため、`bundle lock` だけでも先に静的確認して隔離する。候補作成と導入を分け、個別移行では対象gemと不可欠な関連セットだけを更新する。
- 対応版の `bundle lock --update <対象gem...> --minor --strict` は一括候補の補助になる。`--minor` 単体は厳格な制約とみなさず、0.x・間接依存を含む全差分を分類する。無指定の全更新にmajorの選定を任せない。
- 対応する `CHECKSUMS` を使い、不一致を再生成で消さない。未署名だから安全／悪性と決めず、配布物・gemspec・extension・取得バイナリを先に読む。検査済みlockfile・専用cache・frozen/local相当で導入し、必要な処理だけを隔離で動かす。npmと同等の全script抑止機能があると仮定しない。
- 既存の `bundler-audit` 等を利用できればDBと対象を確認して使う。Rails generator・code mod・DB移行も事前確認と隔離を適用し、ダミーDBで動作と復元を試す。native buildの都合でホストのコンパイラやOSを勝手に更新しない。
- [Rubyの版方針](https://www.ruby-lang.org/en/news/2013/12/21/ruby-version-policy-changes-with-2-1-0/)、[Ruby配布物](https://www.ruby-lang.org/en/downloads/)、[bundle lock](https://guides.rubygems.org/command-reference/bundle-lock/)、[Bundler checksum](https://bundler.io/blog/2024/12/19/bundler-v2-6.html)

## Node・npm／pnpm／Yarn

- 同一majorでも、Nodeの保守状況・engines・同梱npm・peer依存・native addonの対応を確認する。Nodeの公式アーカイブはrelease key・署名済みchecksum・実物を照合する。Node更新後の実行検証では必要なaddonを新環境で再ビルドして動作確認する。
- npmは候補用manifestと対応版の `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` 等で解決し、全依存差分を読む。個別更新では対象と不可欠な関連依存だけを変える。解決結果が保留版を含むなら導入元も保留し、lockfile削除や `npm audit fix --force` で解消しない。
- 取得済み依存は実行前に配布物を調べ、対応する `npm audit signatures` を署名／attestationの補助検証に使う。最終導入は確認済みlockfileの `npm ci --ignore-scripts` と専用cache等を使い、必要なscriptだけ内容確認後に隔離で動かす。`npm test`／`npm run` 本体もコード実行である。
- pnpmの `ignoreScripts` だけではpnpmfileを止めない。Yarnの `yarnPath`／pluginsは起動時から影響し、`enableScripts: false` だけではworkspaceのscript抑止が不十分な場合がある。hook抑止・build許可・lockfile-only・frozen/immutable・skip-buildは導入版に合う方法を選び、全件build許可で通さない。
- `packageManager` 等による管理ツールの取得・版切替も供給網確認に含める。Corepack経由でも未検査の版を即実行しない。既存のauditでprivate名の送信先と間接依存の範囲を確認する。通常の `npm audit` は [対象コードを実行しない監査照会](isolation.md#5-対象コードを実行しない監査照会) の条件を満たす場合に取得用プロセスで行える。`audit fix` は導入処理を含むため監査照会に使わない。
- [Node配布物の検証](https://github.com/nodejs/node/blob/main/README.md#verifying-binaries)、[npm install](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-install.md)、[npm ci](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-ci.md)、[pnpm build設定](https://pnpm.io/settings/build)、[Yarn設定](https://yarnpkg.com/configuration/yarnrc)、[Corepack](https://github.com/nodejs/corepack#environment-variables)

## Python・uv／pip／Poetry等

- Python指定、`requires-python`、C拡張・ABI・wheelの有無、OS/arch、environment marker、extras/groupsを確認する。CPythonのfeature releaseは個別移行し、配布署名は対象版の公式方式を使う。全版で同じPGP方式を要求しない。
- uv／Poetry等のlockがあれば、対応版の同期・整合確認機能を使い、uvの `--locked` と整合確認を省く `--frozen` を混同しない。platform・Python版・marker・extras/groups別の解決範囲とbuild依存を調べ、固定できていない部分を記録する。Pipenv等の既存方式でも同じ基準を満たす公式手順を使う。
- pipのrequirements方式では、全依存の正確な版・取得元・対象環境・検査済み配布物hashを記録し、対応する `--require-hashes` 等で再照合する。lockfileの存在を必須にせず、単なるインストール済み版一覧を出所と全対象環境の再現性の証明にしない。
- metadata取得・download／解決でもbuild backend・`setup.py`・pluginが動き得る。`venv` やbuild isolationはセキュリティ境界ではなく、`--no-build` 等ですべてのbackend実行が止まるとも仮定しない。wheelの `.pth`、`sitecustomize`、`usercustomize` 等の起動時コードも調べる。wheelがなければsource buildとbuild依存をレビューして隔離し、保護を勝手に外さない。
- index設定と依存ごとの出所を確認する。private/publicを併用、特に `--extra-index-url` を使う構成では、内部依存の同名packageを公開元から採用していないか調べる。uv等のPython自動取得も事前確認し、既存の `pip-audit` 等でも依存解決・backend評価を伴う処理は隔離する。再解決やコード評価を伴わない照会だけを行える場合は [監査専用プロセスの条件](isolation.md#5-対象コードを実行しない監査照会) を確認する。
- [Python互換性方針](https://peps.python.org/pep-0387/)、[PyPA versioning](https://packaging.python.org/en/latest/discussions/versioning/)、[pipの安全な導入](https://pip.pypa.io/en/stable/topics/secure-installs/)、[pip build system](https://pip.pypa.io/en/stable/reference/build-system/)、[pip index併用の注意](https://pip.pypa.io/en/stable/cli/pip_install/#examples)、[uvの同期](https://docs.astral.sh/uv/concepts/projects/sync/)、[Poetry CLI](https://python-poetry.org/docs/cli/)、[Python署名情報](https://www.python.org/downloads/metadata/pgp/)、[Python起動時処理](https://docs.python.org/3.13/library/site.html)

## テストと3言語の連携を確認する

CI・README・既存設定から変更に関係するコマンドを選ぶ。利用可能な範囲で追加検証し、未実施の工程と理由を記録する。下表のツールを新規導入したり存在しないコマンドを一律要求したりしない。実行には隔離条件を適用し、基準用は現在版・更新前グラフを照合して測る。追加検証は承認済み snapshot を別 RUN へ渡し、必要な導入・照合・選択したチェック・証拠保存を worker の終了前に完了する。反映後の修正は [再確認手順](isolation.md#反映後に修正が必要になった場合)で当該更新分だけを安全に取り下げ、更新前グラフから修正済み候補を新しい静的計画で確認し直す。許可差分の反映は [保存・反映契約](isolation.md#6-検証した差分を保存して対象へ反映する)に従い、ホストへ依存を導入しない。

| 系統 | 既存構成に応じて確認すること |
| --- | --- |
| Ruby | RSpec／Rails test等、lint、native gemのロード、Rails等の起動・asset連携 |
| Node | 採用管理ツールのtest・lint・型チェック・build、関連workspace、成果物の起動・import、native addon |
| Python | pytest／unittest等、lint・型チェック、必要なbuildと配布物からのimport／公開API実行、worker／CLIの主要処理 |
| 混在 | Rails等のAPI → Nodeの画面／asset → Python worker → 保存結果の再表示など、存在する連携経路の契約と結果 |

変更した依存から利用箇所へたどり、各系統のテストと横断経路を対応づける。3言語がすべてある前提で経路を作らず、実在するAPI・メッセージ形式・シリアライズ・保存結果をダミー環境で確認する。Webは組み込みブラウザで実操作し、CLI／ライブラリ等は対象別の実行確認を行う。
