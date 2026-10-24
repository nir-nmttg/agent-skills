# 管理系統を見分けて更新方法を選ぶ

両スキルで使う手引き。最初に下表で管理系統を見分け、該当する節だけを読む。複数言語なら全系統を一覧化し、各スキルの一括／個別の境界を守る。表は対応言語の上限ではない。

## 静的に確認する入口

| 系統 | 主な manifest・固定情報・環境指定 |
| --- | --- |
| JavaScript／TypeScript | `package.json`、npm/pnpm/Yarn の lockfile、workspace、`packageManager`、`.node-version`／`.nvmrc` |
| Ruby | `Gemfile`、gemspec、`Gemfile.lock`、`.ruby-version`、Bundler の設定 |
| Python | `pyproject.toml`、requirements／constraints、`uv.lock`／`poetry.lock`／`pylock.toml`／`Pipfile.lock`、`setup.py`／`setup.cfg`、`.python-version` |
| Java／Kotlin・JVM | `pom.xml`、`.mvn/`、`build.gradle(.kts)`／`settings.gradle(.kts)`、version catalog・lock・verification metadata、wrapper、JDK toolchain |
| Go | `go.mod`／`go.sum`、`go.work`／`go.work.sum`、vendor、`go`／`toolchain` 指定 |
| Rust | `Cargo.toml`／`Cargo.lock`、workspace、`rust-toolchain(.toml)`、`.cargo/config.toml` |
| .NET | `global.json`、project／solution、`Directory.*.props/targets`、`packages.lock.json`／`packages.config`、`NuGet.Config`、tool manifest |
| PHP | `composer.json`／`composer.lock`、PHP と extension の指定、Composer 設定 |
| 全系統共通 | CI、コンテナ、`.tool-versions`／`mise.toml` 等、private registry・mirror、ローカル／Git 依存、ビルド・テスト設定 |

- 存在する構成から判断し、表のファイルを機械的に追加しない。採用中の管理ツール・vendor を維持し、別の製品や lock 方式への移行を混ぜない。グローバルの更新は依頼された範囲だけ扱う。
- 版固定と出所検証を分ける。lockfile がない系統は既存の方式で、直接・間接・ビルド／plugin 依存の全解決版・取得元・digest・対象 platform を記録し、検査した配布物と導入後のグラフを再照合する。可変 tag・range・SNAPSHOT を正確な安定版と同等に扱わない。固定・再照合を実現できない候補は保留する。
- 環境本体は公式の配布元・vendor・署名方式・hash と照合し、OS・arch・ABI・コンパイルターゲット・CI matrix を確認する。SDK の同梱ツールや build plugin も変更対象として数える。各製品の公式方針で一括／個別に分類し、ツールの `--minor` や数字の位置だけで互換性を決めない。
- wrapper・plugin・ビルド定義は、版の確認・help・dry-run・依存解決だけでも動き得る。静的に読んだ信頼済みツールを使い、コード実行のある操作には取得時から共通の隔離を適用する。全系統に `--ignore-scripts` や同一の frozen 機能があると仮定せず、検出した版の公式資料で対応を確かめる。
- 監査ツールは既存の信頼済みのものを検出し、対象・DB・例外設定・直接／間接依存の範囲を確認する。未導入なら公式告知や公認 DB で調べ、不足を記録する。監査のために新しいツールを即取得・実行しない。脆弱性照合で配布物のレビューを代替しない。

## JavaScript／TypeScript

- Node は同一 major のサポート中の安定版を一括候補にできるが、同梱 npm・native addon・ABI・engine・peer 依存も確認する。公式アーカイブは release key・署名済み checksum・実物を照合する。Deno・Bun 等はそれぞれの公式方針を調べ、Node の版規則を流用しない。
- npm は候補用 manifest と対応版の `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` 等で解決し、全依存差分を読む。個別更新では対象と不可欠な関連依存だけを変える。取得した依存は実行前に配布物を調べ、対応する `npm audit signatures` を補助にする。最終導入は確認済み lockfile の `npm ci --ignore-scripts` と専用 cache 等を使う。必要な script とテスト本体は隔離内で実行する。
- pnpm の `ignoreScripts` だけでは pnpmfile を止めない。Yarn の `yarnPath`／plugins は起動時から影響し、`enableScripts: false` だけでは workspace の script 抑止が不十分な場合がある。hook・build 許可・lockfile-only・frozen/immutable・skip-build は版に合う方法を選ぶ。`npm audit fix --force` や全件 build 許可で通さない。
- [Node 配布物の検証](https://github.com/nodejs/node/blob/main/README.md#verifying-binaries)、[npm install](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-install.md)、[npm ci](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-ci.md)、[pnpm build 設定](https://pnpm.io/settings/build)、[Yarn 設定](https://yarnpkg.com/configuration/yarnrc)

## Ruby

- Ruby の同一 `X.Y` の patch は一括候補。ブランチ変更は minor 表記でも API 非互換を許すため個別移行として扱う。公式 release の checksum と配布物を照合し、標準添付／bundled gem・Bundler・native extension の組合せも調べる。
- Gemfile/gemspec・plugins は Ruby コードのため `bundle lock` でも隔離する。対応版の `bundle lock --update <対象 gem...> --minor --strict` は一括候補の補助になるが、0.x・間接依存などの分類は別に確認する。個別移行は対象を指定し、無指定の全更新に任せない。
- 対応する `CHECKSUMS` を使い、不一致を再生成で消さない。配布物・extension・hook を先に確認し、lockfile・cache・frozen/local 相当で隔離導入する。npm と同等の全 script 抑止があると仮定しない。既存の `bundler-audit` 等と新しい DB を使い、Rails の generator・DB 移行も隔離で検証する。
- [Ruby の版方針](https://www.ruby-lang.org/en/news/2013/12/21/ruby-version-policy-changes-with-2-1-0/)、[Ruby の配布物](https://www.ruby-lang.org/en/downloads/)、[bundle lock](https://guides.rubygems.org/command-reference/bundle-lock/)、[Bundler checksum](https://bundler.io/blog/2024/12/19/bundler-v2-6.html)

## Python

- CPython の feature release（例：`3.12 → 3.13`）は個別移行として扱い、同一系列の patch を一括候補にする。ライブラリの PEP 440 は SemVer の採用を意味しない。CalVer・epoch・独自形式は各製品の互換性方針で分類する。wheel・C 拡張・ABI・`requires-python`・extras/groups も確認する。
- pip／uv／Poetry 等の既存方式を保つ。uv／Poetry 等の lock があれば対応版の同期・整合確認機能を使い、uv の `--locked` と整合確認を省く `--frozen` を混同しない。pip の requirements 方式では全依存の正確な版と配布物 hash を確認し、対応する `--require-hashes` 等で再照合する。別の lock 方式を無断導入しない。
- metadata 取得や download／解決でも build backend・`setup.py`・plugin が動き得る。`venv` や build isolation はセキュリティ境界ではなく、`--no-build` 等もすべての backend 実行を止めると仮定しない。wheel がない場合も保護を外さず、source build と build 依存を別途レビューして隔離する。
- CPython の配布署名は対象版の公式方式を使い、全版で同じ PGP 検証を要求しない。既存の `pip-audit` 等も依存解決を含めて隔離し、既知脆弱性の照合結果として扱う。
- [Python 互換性方針](https://peps.python.org/pep-0387/)、[PyPA versioning](https://packaging.python.org/en/latest/discussions/versioning/)、[pip 安全な導入](https://pip.pypa.io/en/stable/topics/secure-installs/)、[pip build system](https://pip.pypa.io/en/stable/reference/build-system/)、[uv の同期](https://docs.astral.sh/uv/concepts/projects/sync/)、[Poetry CLI](https://python-poetry.org/docs/cli/)、[Python 署名情報](https://www.python.org/downloads/metadata/pgp/)

## Java／Kotlin・JVM

- JDK の feature release は個別移行し、採用 vendor の公式配布物・checksum・署名を確かめる。Kotlin の language/tooling release、JDK・Maven／Gradle・plugin・framework の対応表、bytecode target を確認する。数字の末尾だけで patch と判断しない。
- Gradle は既存の dependency lock と verification metadata を別々に確認する。新規に生成した checksum/keyring を無条件に信頼せず、公式発行者や既知の鍵等で裏づける。Maven に一律の標準 lockfile があると仮定せず、親 POM・BOM・plugins・extensions・annotation processor を含む全解決版と検証済み artifact を記録する。
- wrapper の distribution と wrapper JAR 自体の検証を分ける。Gradle の init/settings/build script・buildSrc・included build、Maven の extensions/plugins は help や dependency tree の取得段階から実行に影響する。ホストの設定・認証を渡さず解決から隔離する。`SNAPSHOT`・changing 依存・動的 range は一括候補に混ぜない。
- [JDK 移行ガイド](https://docs.oracle.com/en/java/javase/21/migrate/preparing-migration.html)、[Kotlin releases](https://kotlinlang.org/docs/releases.html)、[Gradle locking](https://docs.gradle.org/current/userguide/dependency_locking.html)、[Gradle verification](https://docs.gradle.org/current/userguide/dependency_verification.html)、[Gradle Wrapper](https://docs.gradle.org/current/userguide/gradle_wrapper.html)、[Maven Wrapper](https://maven.apache.org/tools/wrapper/index.html)、[Maven 再現可能なビルド](https://maven.apache.org/guides/mini/guide-reproducible-builds.html)

## Go

- Go 本体の `1.N → 1.N+1` は公式が major release と呼ぶ機能更新のため個別移行し、同一 `1.N` の patch を一括候補にする。module の major と import path の変更は本体と別に分類する。
- `go.sum` は一般的な全グラフの lockfile ではない。`go.mod`・workspace・vendor と実際の採用グラフを合わせて比較する。`replace`／`exclude`、private module、proxy／checksum DB の除外設定を調べ、公開 DB による裏づけがない範囲を記録する。
- 通常の go コマンドでも toolchain 指定や `GOTOOLCHAIN` により別の toolchain を取得・実行する場合がある。最初の版確認前に選択と自動取得を調べ、検査済み toolchain・専用 cache を使う。`go generate`／`go run`／`go install`・cgo 等はコード実行として隔離する。既存の `govulncheck` 等で本体・module の対応範囲を確認する。
- [Go release 方針](https://go.dev/doc/devel/release)、[toolchain 選択](https://go.dev/doc/toolchain)、[module と整合性](https://go.dev/ref/mod)、[脆弱性検査](https://go.dev/doc/security/vuln/)

## Rust

- crate の互換更新と toolchain・MSRV・edition の変更を分ける。Cargo の `0.y.z` の y 増加、`0.0.z` の z 増加も個別扱いにする。crate の minor でも MSRV が上がる場合があり、追加の toolchain 移行が必要なら関連性を記録して分離または最小セットにする。
- 既存の Cargo.lock 方針を保ち、registry checksum・Git commit・path／vendor・features・target を比較する。対応する `--locked` は lock 変更を拒否し、`--frozen` は offline も含むが、build script・proc-macro・外部通信を OS で遮断する機能ではない。
- `build.rs` と proc-macro はコンパイル時にホスト上で実行される。rustup の override・自動取得、Cargo の credential provider・runner／wrapper も確認し、解決から必要な隔離を適用する。既存の `cargo-audit`／`cargo-deny` 等では対象 lock・advisory DB・例外を確認する。
- [Cargo SemVer](https://doc.rust-lang.org/cargo/reference/semver.html)、[MSRV](https://doc.rust-lang.org/cargo/reference/rust-version.html)、[locked/frozen](https://doc.rust-lang.org/cargo/commands/cargo-fetch.html)、[build script](https://doc.rust-lang.org/cargo/reference/build-scripts.html)、[proc-macro](https://doc.rust-lang.org/reference/procedural-macros.html)、[rustup override](https://rust-lang.github.io/rustup/overrides.html)

## .NET

- SDK・runtime・TargetFramework・RID・workload・NuGet package を別々に追跡する。SDK の feature band、`global.json` の `rollForward`、target/runtime 系列変更を単純な patch とみなさず、公式の互換性根拠と移行ガイドで一括／個別を判断する。根拠不明なら個別移行として保留する。
- PackageReference・`packages.config`・central package 管理を区別する。既存の `packages.lock.json` と対応版の locked mode 等を使い、全間接依存・build asset を含めて固定・再照合する。feed・package source mapping・trusted signer の設定を緩めない。
- `dotnet restore` も MSBuild によるコード実行の境界になる。project／SDK・親ディレクトリも含む props/targets の自動 import を先に確認し、候補解決から隔離する。検査済み SDK・package cache と対応版の no-restore 相当を使う。NuGetAudit 等は版によって直接依存だけを調べる場合があるため、間接依存も対象にした根拠を記録する。
- [global.json と SDK 選択](https://learn.microsoft.com/en-us/dotnet/core/tools/global-json)、[PackageReference の lock](https://learn.microsoft.com/en-us/nuget/consume-packages/package-references-in-project-files)、[NuGet security](https://learn.microsoft.com/en-us/nuget/concepts/security-best-practices)、[MSBuild security](https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-security-best-practices)、[NuGetAudit](https://learn.microsoft.com/en-us/nuget/concepts/auditing-packages)

## PHP

- PHP の `X.Y` ブランチ変更は非互換を含み得るため個別移行し、同一系列の patch を一括候補にする。PHP 本体・extension・Composer・依存 package を区別し、実環境と `config.platform` の擬似環境を混同しない。
- 候補 lock を作る update と、確認済み lock からの install を分ける。lock の content-hash は配布物全体の真正性保証ではなく、dist/source の取得先・reference・実物を別に確認する。plugins は各種コマンドで動き得るため、対応版の `--no-plugins`／`--no-scripts` を取得時から適用し、必要な処理だけレビュー後に隔離内で動かす。
- 対応版の audit と実 PHP／extension の platform 検証を使う。`--ignore-platform-reqs` 等で互換性の失敗を消さない。共通の供給網確認と OS 隔離をフラグだけで代替しない。
- [PHP 保守方針](https://www.php.net/supported-versions.php)、[PHP 移行ガイドの例](https://www.php.net/manual/en/migration72.php)、[Composer 基本動作](https://getcomposer.org/doc/01-basic-usage.md)、[未信頼 package の扱い](https://getcomposer.org/doc/faqs/how-to-install-untrusted-packages-safely.md)、[Composer CLI](https://getcomposer.org/doc/03-cli.md)

## 手引きにない言語・管理系統

言語名だけで対象外にしない。静的な構成の検出 → 公式の版・互換性方針 → 配布元と全依存の固定・検証 → 解決／ビルド時の実行境界 → 既存テストと対象別の実操作の順に、同じ基準で調べる。コンパイラ、SDK、生成器、ビルド plugin も対象に含める。

公式手順や安全な固定・隔離方法を確認できない部分は、推測したフラグを使わず具体的な不足と再開条件を記録して保留する。確認済みの独立した部分は進め、言語の一覧があることだけで全系統の動作検証済みとは報告しない。
