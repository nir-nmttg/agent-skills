# 管理方法ごとの個別移行の注意点

採用中の管理方法と検出した版の公式資料で、一件の更新に必要な操作を選ぶ。下記は候補用コピー・隔離環境内での例であり、機械的に全コマンドを実行しない。project-local の未検査バイナリを版の確認や `--help` のために起動しない。

## Node・Ruby などのランタイム

- `.node-version`、`.nvmrc`、`.ruby-version`、`.tool-versions`、`mise.toml`、manifest の engines/ruby、CI、コンテナから実際の指定箇所を特定し、一件の移行で同期する。既存の管理ツールを使い、ホスト全体の既定版や OS のランタイムを切り替えない。
- Node の major 更新は、移行ガイド・リリースノート、サポート期間、npm の同梱版、V8/OpenSSL、削除 API、native ABI と addon の対応を確認する。LTS の状態を実行時に公式資料で確認し、固定の版番号をスキルに埋め込まない。
- Ruby の `3.3 → 3.4` のようなブランチ更新も API 非互換を許すため一件ずつ扱う。文法・標準添付／bundled gem の変更、Bundler、C extension、Rails 等の対応条件と platform を確認する。
- ランタイムと周辺ライブラリの同時更新が必須なら、最小の不可分セットと必要性を記録する。分離できる場合は互換性のある範囲へ先にそろえ、各段階で検証する。管理ツール本体の更新が必要なら依頼範囲を確認する。
- Node の配布物は公式 release key・署名済み `SHASUMS256.txt.asc`・アーカイブの hash を照合する。Ruby は公式 release/download の checksum と照合する。管理ツールや Docker image 経由でも取得元・署名／digest・検証できない点を記録する。

## npm

- manifest、lockfile／shrinkwrap、workspaces、`.npmrc`、`packageManager` を読む。対象と必要な peer 依存以外を更新せず、major を上げる一件の採用版と新たな engine 条件を固定する。
- 候補用 manifest を変更し、必要なら `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` で解決する。最終的に保つ範囲指定と候補 lockfile を合わせて確認し、追加された間接依存まで検査する。`npm update` や `npm audit fix --force` に major の移行判断を任せない。
- code mod が推奨されても、`npx --yes <tool>` でそのまま実行しない。ツール自身の版・配布物・実行範囲も確認し、隔離内で使い、生成された全差分を読む。手作業が小さければ移行ガイドに沿って直す。
- scripts 抑止と隔離で取得した依存を実行前に調べる。対応版の `npm audit signatures` は取得済みの依存を検証する工程で使う。signature/provenance の成功は悪性コードの不在を保証しない。
- 最終導入は確認済み lockfile の `npm ci --ignore-scripts` と事前 cache を基本にし、必要な script だけ確認後に隔離で実行する。テスト・ビルド本体もコード実行であり、`ignore-scripts` だけを保護として実行しない。

## pnpm・Yarn

- 管理ツールを移行せず、採用中の版の更新・lockfile-only・script 抑止・frozen/immutable 機能を使う。管理ツール自身の major 移行が不可欠なら別の一件または理由の明確な最小セットにする。
- pnpm hook、Yarn の `yarnPath`・plugins・patch/resolution も実行前に確認する。pnpm の `ignoreScripts` だけでは pnpmfile を止められない。build 許可の設定名は版で変わるため、公式文書に合わせ必要なパッケージだけ許可する。
- Yarn は Classic／現行系を区別する。現行系の対応する `--mode=update-lockfile`／`--mode=skip-build` を調べる。`enableScripts: false` だけで workspace の script まで停止すると仮定しない。
- release age の設定は補助として利用し、fallback・日時不明・lockfile 信頼による検査省略を確認する。全変更版を実際に調べる。lockfile の形式更新で大きな差分が出る場合は、依存変更と区別して説明し、無関係な形式更新を混ぜない。

## RubyGems・Bundler

- Gemfile/gemspec、`Gemfile.lock`、`.bundle/config`、plugins の取得元・GIT/PATH・platform を読む。Gemfile/gemspec は Ruby コードのため、`bundle lock` でも隔離を先に適用する。
- 対象 gem の制約を移行先へ合わせ、対応版の `bundle lock --update <対象 gem...>` 等で必要な範囲だけ再解決する。無指定の `bundle update` で全 major を同時に進めない。Rails 等の公式な関連セットは全構成と理由を記録する。
- `RUBY VERSION`、`BUNDLED WITH`、必要な platform と checksum を確認する。対応版の `CHECKSUMS` を使い、不一致を再生成や検証無効化で消さない。Bundler 自身の変更で lockfile が変わる場合も、差分の理由と採用版を記録する。
- gem 配布物・gemspec・native extension・install hook を確認してから、固定した lockfile と専用 cache で隔離導入する。`bundle install` に npm と同じ全 script 抑止機能があると仮定しない。frozen／deployment／local の指定は現在の版と既存設定に合わせる。
- Rails の generator・upgrade task も実行前に調べ、生成された全差分を確認する。DB の変更はダミー DB で移行と復元を試し、本番や共有 DB に実行しない。`bundler-audit` 等の実行にも隔離と新しい DB が必要で、不足をゼロ件にしない。

## その他のランタイム・管理系統

Python、Java 等も公式の移行ガイド、lock/frozen 相当、出所検証と取得・実行の分離を確認して一件ずつ扱う。非 SemVer の互換性規則を調べ、手順不明なら推測したコマンドを使わず候補と不足を報告する。別の管理製品へ移行しない。

## 公式資料

- [Node の公式 README と配布物の検証](https://github.com/nodejs/node/blob/main/README.md)、[release key](https://github.com/nodejs/release-keys)
- [Ruby のバージョン方針](https://www.ruby-lang.org/en/news/2013/12/21/ruby-version-policy-changes-with-2-1-0/)、[保守状況](https://www.ruby-lang.org/en/downloads/branches/)、[配布物](https://www.ruby-lang.org/en/downloads/)
- [npm install の公式文書](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-install.md)、[npm ci の公式文書](https://github.com/npm/cli/blob/latest/docs/lib/content/commands/npm-ci.md)
- [pnpm build 設定](https://pnpm.io/settings/build)、[依存解決設定](https://pnpm.io/settings/dependency-resolution)
- [Yarn install](https://yarnpkg.com/cli/install)、[Yarn 設定](https://yarnpkg.com/configuration/yarnrc)
- [bundle lock](https://guides.rubygems.org/command-reference/bundle-lock/)、[Gemfile](https://guides.rubygems.org/gemfile/)、[Bundler checksums](https://bundler.io/blog/2024/12/19/bundler-v2-6.html)
