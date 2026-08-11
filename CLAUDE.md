# CLAUDE.md

EC-CUBE 4 の汎用 Docker 環境。本体はイメージにベイクし、`app/`（Customize / template /
DoctrineMigrations / config / Plugin）と `html/user_data`（独自 CSS/JS）、`frontend`（scss
ソース）だけを bind-mount して Git 管理する。

## 原則

- **EC-CUBE 本体を直接編集しない**。用途ごとの置き場所:
  - PHP カスタマイズ（Controller/Entity/Form/Service/Event/Twig拡張/Command）→ `app/Customize/`
  - テンプレート上書き → `app/template/`
  - スキーマ変更（migration）→ `app/DoctrineMigrations/`
  - プラグイン（開発・ストア導入）→ `app/Plugin/`（mount 済み・Git 管理）
  - 独自 CSS/JS → `html/user_data/assets/{css,js}`。本体 `default_frame.twig` が
    `customize.css` / `customize.js` を自動読込する（上書き Twig 不要）。scss ソースは
    `frontend/scss/`、ビルドは `bin/assets.sh`。
- **バージョンは `.env` の `ECCUBE_VERSION`**（build-arg）。切替は `bin/switch-version.sh`。
- **framework 級設定（monolog 等）は `app/config/eccube/packages/`**。entrypoint が起動時に
  本体の `app/config/eccube/packages/` へマージする（既定は消さない）。
- 既定は本番モード。開発でデバッグするときだけ `.env` を `APP_ENV=dev` にする。
- **本番モードでキャッシュを消すときは `cache:clear` だけでは足りない。** Redis 上の
  Doctrine メタデータ（`cache:pool:clear --all`）と OPcache（php-fpm へ USR2）も
  消す。`opcache.validate_timestamps=Off` のためファイルを更新しても php-fpm は
  古いコンパイル結果を返し続ける。**OPcache は CLI では無効**なので `bin/console`
  からは正常に見え、ブラウザだけ壊れる。`bin/plugin.sh` の各コマンドは両方消す。
- **プラグインの install/enable/disable は前後でキャッシュ操作が要る。**
  `doctrine.yaml` の `auto_generate_proxy_classes` は `%kernel.debug%`（prod では
  false）なので、Doctrine のプロキシはウォーマーでしか作られない。EC-CUBE 本体の
  プラグインコマンドは内部で `cache:clear --no-warmup` までしかやらないため、
  **前**に `cache:pool:clear --all`、**後**に warmup 込みの `cache:clear` が必要。
  怠るとこうなる:
  - 前を怠る → `Property Eccube\Entity\Product::$BundleItems does not exist` で
    コマンドが異常終了する（`var/cache` を消しても直らない。実体は Redis 側）。
  - 後を怠る → トレイトで足した getter が**例外も出さずに空のコレクション**を返す。
    `findBy()` は件数を返すのに `$Product->getBundleItems()` は 0 件、という
    食い違いになり、プラグインの Processor が黙って何も記録しない。
  `bin/plugin.sh` の各コマンドは両方やる（`prepare_plugin_command` / `warm_cache`）。

- **テストは `bin/test.sh` から実行する**。素の `vendor/bin/phpunit` だとコンテナの
  `APP_ENV=prod` が勝って prod カーネルが起動し、`WebTestCase` 系が
  「framework.test config is not set to true」で全部落ちる（`bin/test.sh` が
  `-e APP_ENV=test` を渡している）。テスト設定の DAMA が各テストを
  ロールバックするので DB は汚れない。メールは `packages/test/messenger.yaml` で
  テストだけ同期送信。詳細は README「ユニットテスト」。
- **テスト設定は PHPUnit のバージョン別に 2 本ある。** EC-CUBE 4.2/4.3 は PHPUnit 9.6 +
  DAMA 6.x、4.4 は PHPUnit 11 + DAMA 8.x で、設定の書式が相互に非互換
  （DAMA の登録が `<listeners><listener>` ↔ `<extensions><bootstrap>`、カバレッジ対象が
  `<coverage>` ↔ `<source>`。DAMA 8.x には `PHPUnitListener` クラス自体が無い）。
  - `phpunit.xml` … PHPUnit 9 以前（4.2 / 4.3）
  - `phpunit.11.xml` … PHPUnit 10 以降（4.4〜）
  - **どちらを使うかは `bin/test.sh` がコンテナの `vendor/bin/phpunit` の実バージョンを
    見て選ぶ**（`.env` の `ECCUBE_VERSION` からは推測しない）。片方だけ直して
    もう片方を放置しない。
- **書式が合わないと PHPUnit は警告を出して読み飛ばすだけ**で、**DAMA のロールバックが
  黙って無効化される**。テストが本番と同じ DB へ書き込み続け、数千件を投入するテスト
  （プラグインの大規模カタログ検証など）でフロントが商品一覧のシステムエラーで落ちる。
  `bin/test.sh` は実行前に DAMA の登録方法を DOM で検証し、実行後に
  「The configuration file did not pass validation!」が出ていたらテストが緑でも
  失敗扱いにする。このエラーが出たら設定の書式を疑う。
- **設定ファイルを編集したら `docker compose up -d --force-recreate ec-cube`。** 単一
  ファイルの bind mount（`./phpunit.xml:/var/www/html/phpunit.xml:ro`）はホスト側で
  書き換えても inode が変わってコンテナ側へ反映されないことがある。中途半端な内容を
  掴んだまま「Premature end of data」等で落ちる。`bin/test.sh` がホストとコンテナの
  バイト数を突き合わせて検出する。
- **性能/スケール（Tier 1）**: php-fpm は `.env` の `PHP_FPM_*`、OPcache は entrypoint が
  `APP_ENV` で切替、Redis 共有キャッシュは `app/config/eccube/packages/cache.yaml`、DB は
  `docker/mariadb/conf.d/`、nginx は gzip/静的キャッシュ済み。詳細は README「大規模アクセス」。
- **セッション Redis 共有（Tier 2）**: 専用 `redis-session` に保存し複数ホストで共有。
  本体の SameSite ハンドラは維持し内側だけ `Customize\Session\RawRedisSessionHandler` に
  差し替え（`app/Customize/Resource/config/services.yaml`、`SESSION_REDIS_URL`）。
- **アップロード画像（Tier 2）**: `html/upload` は専用ボリューム `eccube_upload` に分離。
  複数ホストは NFS/EFS ドライバに差し替えて共有。`down -v`（reset/switch-version）で
  ローカルデータは消えるので事前バックアップ。詳細は README「アップロード画像の共有ストレージ」。
- **複数ホスト + LB（Tier 2）**: 各アプリホストは `compose.app.yaml`（db/redis を含まない
  app 層のみ、外部共有サービスを参照）。init ロール 1 台だけ `ECCUBE_SKIP_DB_INIT=0` で
  migrate、他は 1。HTTPS 終端 LB では `TRUSTED_PROXIES` 必須（本体未配線を
  `app/config/eccube/packages/trusted_proxies.yaml` で補う）。LB 例は `docker/nginx/lb.conf.example`。

## よく使う操作

```bash
bin/init.sh                    # 初回セットアップ
bin/upgrade.sh ~4.3.2          # バージョンアップ（データ保持・運用環境向け）
bin/switch-version.sh ~4.2.0   # バージョン切替（データ破棄・開発用）
bin/reset.sh                   # DB 初期化
bin/publish.sh                 # 本番構成で起動
docker compose exec ec-cube runuser -u www-data -- php bin/console <cmd>

bin/assets.sh build            # 独自 scss → html/user_data/assets/css/customize.css
bin/assets.sh watch            # 上記を監視ビルド（dev の node サービス）
bin/assets.sh core-build       # 本体テーマ丸ごとの純正ビルド（Gulp/Webpack・Git 管理外）

bin/test.sh                    # テスト（app/Customize/Tests）
bin/test.sh app/Plugin/Foo/Tests  # パス指定でプラグインのテストも同じ設定で走る

# プラグイン（dev で app/Plugin が rw のとき）
bin/plugin.sh add git@github.com:you/MyPlugin.git   # clone→install→enable
bin/plugin.sh list                                  # 導入状況（enabled/version）
bin/plugin.sh reload                                # PHP/config 変更後のキャッシュ一掃
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:generate <Name>
```

## 開発フロー（重要）

- **`main` へ直接コミット・直接プッシュしない。** 変更は必ず作業ブランチを切り、
  プルリクエストを作成する。
- **マージはオーナー（kurozumi）が行う。** 明示的に「マージして」と指示されない限り、
  自分で `gh pr merge` しない。
- リポジトリ初期化時の初回プッシュのみ、例外的に直接 `main` へ反映済み。
