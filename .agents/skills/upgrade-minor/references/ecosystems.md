# 管理方法ごとの更新の注意点

プロジェクトが採用する管理方法と検出した版を使う。以下は候補用コピー・隔離環境内での手段の例であり、一律に実行するコマンド列ではない。実行前に公式文書と `--help` で対応を確認し、project-local の未検査コードを `--help` のために実行しない。

## Node・Ruby などのランタイム

- `.node-version`、`.nvmrc`、`.ruby-version`、`.tool-versions`、`mise.toml`、manifest の engines/ruby、CI・コンテナから、実際に使う指定を特定する。全部が存在する前提で追加しない。Docker image は tag の意味・署名と digest の変化も確認する。
- Node は同一 major のサポート中の安定版を候補にする。Ruby のブランチ変更は minor 番号でも API 非互換を許すため、通常は同一 `X.Y` の patch をまとめる。別ブランチへの移行は `$upgrade-major` に回す。
- 既存の信頼済み管理ツールを使って、プロジェクトで選べる形で導入する。管理ツールの plugin・project hook・ダウンロードスクリプトも先に読む。ホスト全体の既定版切替や `sudo` での上書きをしない。
- Node の公式アーカイブは、公式 release key と署名済み `SHASUMS256.txt.asc`、配布物の hash を検証する。Ruby は公式 release/download の checksum と照合する。管理ツールに任せる場合も、取得元・検証方法・未確認点を記録する。
- 同梱 npm、Bundler、native ABI、OpenSSL、ビルド環境、CI matrix の互換性を見る。管理ツール自体や同梱ツールの major 移行が必要なら、一括候補から分離して個別の移行計画を立てる。

## npm

- `packageManager`、`package-lock.json`／`npm-shrinkwrap.json`、workspaces と `.npmrc` を読む。registry、URL/Git 依存、optional/platform 差分を確認する。`npx` や `npm exec` による補助ツールの自動取得・即実行はしない。
- 公式メタデータから採用版を選び、候補用 manifest にその版を反映する。既存の範囲指定を守る最終 manifest とともにレビューし、必要なら `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` で候補 lockfile を生成する。この操作は supply-chain 検査でも全コード実行の抑止でもない。
- `npm update` は範囲内でも想定外の間接依存を更新し得るため、出力された全グラフを検査する。`npm outdated` の wanted/latest のみで採用しない。`npm audit fix --force` で範囲や major を越えて更新しない。
- 取得は scripts 抑止と隔離を適用し、実行前に配布物を確認する。対応版の `npm audit signatures` は取得・展開済みの依存の署名／attestation を検証するために使い、未取得の候補に対する安全判定には使わない。
- 最終導入はレビュー済みの lockfile で `npm ci --ignore-scripts` を基本にし、取得済み cache と対応する offline 設定を使う。必要な lifecycle script だけを内容確認後に隔離で動かす。`ignore-scripts` があっても `npm test`／`npm run` の指定した本体は動くため、テストも隔離する。

## pnpm・Yarn

- 管理ツールの版、registry、workspace、patch/resolution、pnpm hook、Yarn の `yarnPath` と plugins を確認する。lockfile-only の操作でもこれらの実行を防ぐとは限らない。`yarnPath` は管理ツールを起動する時点から影響する。
- pnpm は対応版の lockfile-only・ignore-scripts・hook 抑止・frozen-lockfile を確認して使う。`ignoreScripts` だけでは pnpmfile の実行を防げない。build 許可の設定名は版で異なるため、全件許可や設定名の決め打ちを避ける。
- Yarn Classic と現行系ではオプションが異なる。現行系では対応する `--mode=update-lockfile`／`--mode=skip-build` や immutable 設定を調べる。`enableScripts: false` だけでは workspace の script 抑止が不十分な場合がある。
- release age の設定を持つ版は利用してよいが、新しい版への fallback、時刻不明、既存 lockfile を信用して検査を省く挙動まで確認する。設定に任せ切らず全変更版の日時と配布物を調べる。

## RubyGems・Bundler

- `Gemfile`、gemspec、`Gemfile.lock` の source・GIT/PATH・platform・`RUBY VERSION`／`BUNDLED WITH`、`.bundle/config` と plugins を読む。秘密値は表示しない。Gemfile/gemspec は Ruby コードなので、`bundle lock` だけでも最初から隔離内で扱う。
- 対応版なら `bundle lock --update <対象 gem...> --minor --strict` などで候補を作る。`--minor` だけの指定は優先順位であり、範囲の厳格な制約ではない。全件更新を使う場合も確認済みの候補に限定し、0.x・Ruby 本体・非 SemVer・間接依存の分類を別途確認する。
- 対応版では lockfile の `CHECKSUMS` を使う。初めて checksum を追加する場合は信頼した配布情報で裏づけ、既存値の不一致を再生成で消さない。未署名の gem があること自体を悪性／安全の判定にしない。
- `bundle install` には native extension などのコード実行がある。npm と同等の全 script 抑止フラグがあると仮定しない。gem 配布物・gemspec・extension を先に調べ、固定した lockfile・専用 cache を使って隔離内で導入する。frozen／deployment／local の適用方法は現在の版と既存設定に合わせる。
- `bundler-audit` 等の既存ツールと更新済み advisory DB を利用できる場合は使う。ただし導入済み gems 経由の実行も対象コードの実行として扱い、DB 未更新やツール不足をゼロ件にしない。

## その他のランタイム・管理系統

Python、Java 等も公式の互換性方針、lock/frozen 相当、出所検証、取得と実行の分離が確認できれば同じ基準で扱う。Node 用のフラグを流用せず、対応が不明なら候補と不足情報を報告して保留する。管理系統を別の製品へ移行しない。

## 公式資料

- [Node の配布物と検証](https://github.com/nodejs/node/blob/main/README.md#verifying-binaries)、[release key](https://github.com/nodejs/release-keys)
- [Ruby のバージョン方針](https://www.ruby-lang.org/en/news/2013/12/21/ruby-version-policy-changes-with-2-1-0/)、[保守状況](https://www.ruby-lang.org/en/downloads/branches/)、[配布物](https://www.ruby-lang.org/en/downloads/)
- [npm install の公式文書](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-install.md)、[npm ci の公式文書](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-ci.md)
- [pnpm build 設定](https://pnpm.io/settings/build)、[依存解決設定](https://pnpm.io/settings/dependency-resolution)
- [Yarn install](https://yarnpkg.com/cli/install)、[Yarn 設定](https://yarnpkg.com/configuration/yarnrc)
- [bundle lock](https://guides.rubygems.org/command-reference/bundle-lock/)、[Gemfile](https://guides.rubygems.org/gemfile/)、[Bundler checksums](https://bundler.io/blog/2024/12/19/bundler-v2-6.html)
