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
- **`app/template/` に本体のテンプレートを丸ごと写さない。** 写した瞬間は同じでも、
  本体を上げたときに**古いほうが勝ち続ける**。例外は出ず、直したはずの不具合が
  戻る・新しい項目が出ない、という形で出る。上書きするのは**直すファイルだけ**に
  すること。実際にこのリポジトリには本体と同一の写しが56件あった（末尾の改行しか
  違わなかった）ので消した。
- **プラグインがテーマへ写したテンプレートは追跡しない**（`.gitignore` 済み）。
  無効化→有効化で作り直せる。**店が直したものだけ `git add -f` で追跡する。**
- **バージョンは `.env` の `ECCUBE_VERSION`**（build-arg）。切替は `bin/switch-version.sh`。
- **IDE がライブラリを未定義と言うのは正常。** 本体と `vendor` はボリュームの中だけにあり
  ホストには1ファイルも無い。`bin/ide-sync.sh` で `.ide/` へ写し、PhpStorm の
  **Include Path**（ソースルートではない）に足す。リモートインタプリタを設定しても
  解決しない。バージョンを切り替えたら写し直す。
- **framework 級設定（monolog 等）は `app/config/eccube/packages/`**。entrypoint が起動時に
  本体の `app/config/eccube/packages/` へマージする（既定は消さない）。
- 既定は本番モード。開発でデバッグするときだけ `.env` を `APP_ENV=dev` にする。
- **本番モードでキャッシュを消すときは `cache:clear` だけでは足りない。** Redis 上の
  Doctrine メタデータ（`cache:pool:clear --all`）と OPcache（php-fpm へ USR2）も
  消す。`opcache.validate_timestamps=Off` のためファイルを更新しても php-fpm は
  古いコンパイル結果を返し続ける。**OPcache は CLI では無効**なので `bin/console`
  からは正常に見え、ブラウザだけ壊れる。`bin/plugin.sh` の各コマンドは両方消す。
- **本番モードでは「キャッシュが古い」こと自体はエラーにならない。** ファイルを足しても
  コンパイル済みコンテナには入らないので、**足したサービスやタグだけが例外も 500 も
  出さずに効かない**。実例: 承認対象を決めるタグ付きサービスを1つ足したのに古い並びが
  焼かれたままで、取引先の会員登録が承認制にならなかった。コードもタグも正しいので、
  ソースを読んでもテストを流しても見つからない。切り分けは
  `var/cache/prod/Container*/get<サービス>Service.php` を読んで、期待した定義が
  焼かれているかを見るのが速い。
  **`git pull` でプラグインを更新した直後がいちばん危ない**（ファイルだけ新しくなる）。
  - `bin/plugin.sh reload` はキャッシュの組み立てに失敗したら**止まる**。
    黙って続けると「成功と表示されたのに古いコンテナが残る」ことになり、
    足したサービスやタグだけが効かない状態を自分で作る。warmup は重いので
    `memory_limit` は 1G で回す（`PLUGIN_CACHE_MEMORY_LIMIT` で変えられる）。
  - `bin/plugin.sh doctor` … コンパイル済みコンテナより新しいファイルがあれば挙げる
  - `bin/plugin.sh watch` … 見張って自動で reload。開発中は別のターミナルで放っておく
- **`docker compose` のプロジェクト名がずれると、直したつもりで直らない。**
  `compose.yaml` の `name:` と別名でスタックを起動していると、`bin/*.sh` は
  `name:` のほうへ行く。**止まっているスタックにも `exec` は通ってしまう**ので、
  reload も doctor も成功したように見えてブラウザは古いままになる。上の
  「効かないプラグイン」も、元をたどるとこれで reload が空振りしていた。
  `.env` に `COMPOSE_PROJECT_NAME=<稼働中の名前>` を書いて固定する。
  同じ `app/` を bind-mount した二重起動は `app/proxy/entity` を奪い合うので、
  使わないスタックは落としておく。
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
  `bin/plugin.sh` の各コマンドは両方やる（前が `prepare_plugin_command`、後が
  `settle` = 後始末 → test/プール/OPcache 削除 → warmup 込みの `cache:clear`）。
  組み立てを次のリクエスト任せにすると、そこへ別のリクエストやコンソールコマンドが
  重なってコンパイル済みコンテナが書きかけのまま残り、全ページ 500 になる。
  **素の `bin/console eccube:plugin:enable` を直接叩かない。**
- **管理画面（オーナーズストア → プラグイン一覧）から有効化・無効化したら、その直後に
  `bin/plugin.sh reload` を実行する。** 本体の `PluginController` は `cacheUtil->clearCache()`
  しか呼ばず、これは `kernel.terminate` で `cache:clear --no-warmup` を走らせるだけ。
  php-fpm は `opcache.validate_timestamps=0` なので、`opcache_reset()` の届き方と
  メンテナンス解除（`SystemService::disableMaintenanceEvent`）の順序次第で、
  古いエンティティクラスを掴んだままメタデータが作られることがある。結果:

      Unrecognized field: Plugin\CustomerGroup44\Entity\Group::$optionCompanyEntry

  実体（生成された `Group`）にはトレイトで項目があるのに、メタデータ側が知らない、
  という食い違い。プラグインを有効化した直後に、その画面ではなく**フロントの
  別ページ**が落ちるので原因にたどり着きにくい。`reload`（または `doctor`）で直る。
  なお、この2つは `kernel.terminate` の同じ優先度に登録されていて実行順が保証されない。
- **`.maintenance` が残ることがある。** 管理画面からプラグインを操作すると本体が
  `auto_maintenance` を自動で立てる。処理が途中で落ちると消されず、フロントだけ
  503「ただいまメンテナンス中です」になる。**管理画面は素通りできるので気づきにくい。**
  `bin/plugin.sh doctor` が自動で解除する（手動で入れたメンテナンスは残す）。
- **プラグインが勝手に無効へ落ちることがある。** 中断した操作の巻き添えで
  `dtb_plugin.enabled` が 0 になる。無効になっただけでは表向き何も起きないが、
  Doctrine のメタデータに拡張プロパティが残ったままだと
  「Property Plugin\...\Group::$optionEntry does not exist」で画面が落ちる。
  **落ちるのが管理画面の別ページ（レイアウト管理など）なので、原因にたどり着きにくい。**
  `bin/plugin.sh doctor` が「インストール済みだが無効」として挙げる。
- **システムエラーが出たら `bin/plugin.sh doctor`。** 残骸の掃除・無効プラグインの
  検出・エンティティ拡張の反映確認・キャッシュの組み立て直し・主要ページの疎通確認まで
  やる。ページが落ちているときだけ直近の CRITICAL を出す。

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
- **テスト用のコンパイル済みコンテナは `cache:clear` では作り直されない。** テストは
  `APP_DEBUG=0` で走るので、`bin/console cache:clear` が作るデバッグ版
  （`Eccube_KernelTestDebugContainer`）とは別のファイル（`Eccube_KernelTestContainer`）を
  使う。**debug=false のコンテナはファイルの更新を一切見ない**ため、クラスを足しても
  反映されない。症状は「サービスがコンテナに登録されていない」形で出る。フォームの型なら
  `Too few arguments to function ...::__construct(), 0 passed in FormRegistry.php`。
  Symfony が DI を通さず `new` している合図で、コードではなくキャッシュが原因
  （`cache:clear` を何度打っても直らず、1時間溶かした）。`bin/test.sh` が
  `app/Plugin` と `app/Customize` の php/yaml/xml とコンテナの更新時刻を比べ、
  新しいものがあれば `var/cache/test` を消してから実行する。手で直すなら
  `docker compose exec ec-cube rm -rf var/cache/test`。
- **管理画面の Web テストは `dtb_member` を溜め、放置するとテストが固まる。**
  `Generator::createMember()` は faker の `word` から未使用の `login_id` を探すが、
  **ja_JP の単語は 182 語しか無い**。Web テストの Member はロールバックされないため、
  溜まった数が単語数に達すると `do/while` を永久に抜けられない。エラーも出ず
  PHP が CPU を回し続けるだけで、原因が分かりにくい（実際に 2 回踏んだ）。
  `bin/test.sh` が実行前に検出して `login_id` を `leaked-<id>` へ退避する。
  手で直すなら `UPDATE dtb_member SET login_id = CONCAT('leaked-', id) WHERE id > 2;`。
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

bin/ide-sync.sh                # IDE 用に本体・vendor を .ide/ へ写す（--proxy / --clean）

bin/assets.sh build            # 独自 scss → html/user_data/assets/css/customize.css
bin/assets.sh watch            # 上記を監視ビルド（dev の node サービス）
bin/assets.sh core-build       # 本体テーマ丸ごとの純正ビルド（Gulp/Webpack・Git 管理外）

bin/test.sh                    # テスト（app/Customize/Tests）
bin/test.sh app/Plugin/Foo/Tests  # パス指定でプラグインのテストも同じ設定で走る

# プラグイン（dev で app/Plugin が rw のとき）
bin/plugin.sh add git@github.com:you/MyPlugin.git   # clone→install→enable
bin/plugin.sh list                                  # 導入状況（enabled/version）
bin/plugin.sh reload                                # PHP/config 変更後のキャッシュ一掃
bin/plugin.sh watch                                 # 変更を見張って自動で reload
bin/plugin.sh doctor                                # システムエラー時の点検と修復
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:generate <Name>
```

## 開発フロー（重要）

- **`main` へ直接コミット・直接プッシュしない。** 変更は必ず作業ブランチを切り、
  プルリクエストを作成する。
- **マージはオーナー（kurozumi）が行う。** 明示的に「マージして」と指示されない限り、
  自分で `gh pr merge` しない。
- リポジトリ初期化時の初回プッシュのみ、例外的に直接 `main` へ反映済み。
