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
    **ビルド先は `customize-theme.css`。`customize.css` へ書き出さない。**
    あちらは管理画面（コンテンツ管理 → CSS 管理）が `dumpFile` で直接書き換える
    ファイルで、同じ場所へビルドすると**店が画面から入れた CSS がビルドのたびに
    黙って消える**。`customize.css` 先頭の `@import` がテーマを読み込む。
    **その `@import` を消さない／上に何も書かない**（先頭以外の `@import` は
    CSS の仕様で無効になり、テーマが丸ごと効かなくなる）。
  - **`html/template/original/assets` と `.base` は eccube-docker では追跡しない。** 店ごとの
  成果物で、tag からの tarball（＝配布物）にそのまま入るため。一度コミットして
  6MB・125 ファイルの 4.4-dev の写しを全利用者に配りかけた。手元の無視は
  `.git/info/exclude`（`.gitignore` に書くと利用者の `git add` まで黙って落ちる）。
- **オリジナルテーマ（コード `original` 固定）は twig と静的物で正反対。** twig は
    `app/template/original/` に直すファイルだけ（フォールバックあり）。静的物は
    `html/template/original/assets/` に**丸ごと**（`asset()` の base_path は 1 本で
    フォールバック無し。1 ファイル欠けると 404）。`bin/theme.sh init` が本体から写し、
    `.base` に版と sha256 を記録。**写しはフォールバック無しで勝ち続ける**ので、
    `bin/upgrade.sh` の最後に `theme.sh diff` で本体側の変更を出す。
    テーマの選択は `.env` の `ECCUBE_TEMPLATE_CODE`（管理画面の選択はコンテナ内 `.env` に
    書かれ、upgrade で消える）。
  - **本体テーマの twig / scss はホストに無い。** `bin/ide-sync.sh` が参照用の写しを
    `.ide/` に作る（twig は `src/Eccube/Resource/template/`、scss は
    `html/template/default/assets/scss/`）。**写しを編集しても反映されない。**
- **`app/template/` に本体のテンプレートを丸ごと写さない。** 写した瞬間は同じでも、
  本体を上げたときに**古いほうが勝ち続ける**。例外は出ず、直したはずの不具合が
  戻る・新しい項目が出ない、という形で出る。上書きするのは**直すファイルだけ**に
  すること。実際にこのリポジトリには本体と同一の写しが56件あった（末尾の改行しか
  違わなかった）ので消した。
- **プラグインはテーマへ何も写さない**（2026-09、11プラグイン）。`dtb_page.file_name`
  も `dtb_mail_template.file_name` もプラグインの中を指す。Twig のローダーの探索先に
  `app/Plugin` が入っているので、写さなくても読める。**テーマを変えても写し直しが
  要らない。** `app/template/default/` は **`.gitkeep` だけ**で、ここにファイルが
  増えていたら店が自分で置いた上書きテンプレート。
  店がテンプレートを直すのは**プラグインテンプレート編集プラグイン**の役目で、
  直した内容はデータベースに残る。ページ管理とメール設定の本文欄は伏せてあり、
  本体がそれでもテーマへ書いた写しは、あちらがその場で消す（本体は読むのを
  ローダーに任せるが、**書くのは必ずテーマ配下**）。
- **ライセンスは Apache-2.0**（`LICENSE`）。商用・受託・再配布とも自由。
  **EC-CUBE 本体は対象外**（ここには含まれず、ビルド時に Packagist から取る。
  本体を一切改変していないので、イメージ内の EC-CUBE は EC-CUBE 自身のライセンス）。
- **バージョンは `.env` の `ECCUBE_VERSION`**（build-arg）。切替は `bin/switch-version.sh`。
  ただし **`.env` に `ECCUBE_IMAGE` があるときは build しないので、この値は使われない。**
  動くのはタグに焼かれたバージョンで、両者は簡単にずれる。`bin/upgrade.sh` は pull した
  イメージの実バージョンを表示して確認を求める。
- **配布イメージは毎週月曜に焼き直される**（`build-image.yml` の `schedule`）。土台の
  `php:8.x-fpm-bookworm` は浮動タグなので、**焼き直すだけで PHP と Debian のパッチが入る。**
  焼くのは**最新リリースのタグ**の Dockerfile（main を焼くと未リリースの変更が配られる）、
  **キャッシュ無し**（apt の layer が当たるとパッチが入らず、焼いた意味が無い）。
  追跡タグ（`4.3` / `4.3-php8.3`）と日付タグ（`4.3-20260907`）だけ動かし、`-vX.Y.Z` は
  「そのリリースの時点」として不変。**本番の推奨は追跡タグ + `bin/deploy.sh`**
  （PHP のパッチに `upgrade.sh` は要らない。PHP は `eccube_app` ボリュームの外）。
  緊急は `workflow_dispatch` の `refresh: true` で当日焼く。
- **PHP は系列ごとに複数焼く**（4.2: 8.1/8.2、4.3: 8.1/8.2/8.3、4.4: 8.2〜8.5。上流 README の
  対応一覧）。`-php` 無しの短いタグは系列の既定（`image_php_for_series`）。phpredis は系列で
  決まる（4.2/4.3: 6.0.2、4.4: 6.3.0）。**matrix と `bin/lib/image.sh` を揃える。**
  DB の版は `.env` の `MARIADB_VERSION` / `PG_VERSION`（image と Doctrine の `serverVersion` の
  両方に効く。`DATABASE_SERVER_VERSION` は外部 DB で版が違うときだけ）。
- **`bin/self-update.sh` の更新対象は `.eccube-docker-paths`。** スクリプト内の配列は控えで、
  **正は「これから入れる版」の一覧**。スクリプト側だけ見ると、新しい版で足したパスが
  初回の更新で届かない（`LICENSE` を足したときに実際にそうなった）。
  **`mapfile` を使わないこと。** bash 4 以降の組み込みで、**macOS の bash は 3.2**。
  `command not found` で `set -e` が働き、何も出さずに死ぬ。
- **「更新」は 3 つあり、別物。** 自分のコードは `bin/deploy.sh`（毎日）、環境（`bin/` や
  compose）は `bin/self-update.sh`、EC-CUBE 本体は `bin/upgrade.sh`。順番は
  self-update → upgrade。逆にすると新しい本体を古いスクリプトで扱うことになる。
  `deploy.sh` はボリュームを作り直さず DB も画像も触らない。メンテナンス表示は
  `deploy:<token>` で立て、失敗したら **OFF にしない**（`doctor` が後始末する）。
  詳細は `docs/distribute.md`。
- **起動系のスクリプトに `up -d --build` を直接書かない。** 配布イメージを使っている
  利用者の環境では、pull したイメージをローカル build で上書きしてしまう。
  build と pull の判定は `bin/lib/image.sh` の `image_provision` に寄せてある。
- **マイナー（4.4 → 4.5）はプラグイン全数の移植を伴う。** パッチ（4.4.1 → 4.4.2）は
  `upgrade.sh` だけで済む。マイナーでは対象版ごとの保守ブランチを切り、コード名・
  パッケージ名・version を置換し、**CI の matrix にも新版を足す**（いまは全プラグインが
  `4.4` 固定で、足さないと新版で一度も検証されない）。**黙って壊れる型が3つある**
  （目印による差し込み・本体の処理への割り込み・本体の副作用への対処）。
  詳細は `docs/upgrade.md`。
- **`app/template` は本番でも rw。** 管理画面（ページ管理・ブロック管理・メール設定の本文）が
  ここに書く。ro だとブロックと新規ページの保存が 500、メール本文は保存エラー（本体は
  `dumpFile` を捕まえていない）。開発では override が rw にしていたので気づかなかった。
  コードの側（`app/Customize` 等）は ro のまま。
- **Linux の本番は `.env` に `PUID` / `PGID`。** entrypoint が www-data の uid を揃える。
  揃えないと、管理画面が書いたファイルを `git pull` が上書きできず、ホストが置いた
  ファイルを管理画面が書けない（欄が空に見える）。macOS は透過なので不要。
- **ディスクに残る状態は、git か backup のどちらかに必ず入る。** 管理画面は DB
  だけでなくファイルにも書く（CSS/JS 管理 → `html/user_data/assets/{css,js}`、
  ページ管理 → `app/template/user_data/`、ブロック管理 → `app/template/<テーマ>/Block/`、
  テーマ切替・セキュリティ設定 → **コンテナ内** `/var/www/html/.env`）。
  `app/template/user_data/` は以前 .gitignore していたが、`dtb_page` の行と対なので
  **DB だけ持って引っ越すとそのページが 500 になる**。追跡に戻した。
  `bin/backup.sh` は 5 点セット（DB / 画像 / 管理画面が書いたファイル＋git に入らない資産 /
  コンテナ内 .env / **ホストの .env**）。`admin-files.tar.gz` は `html/user_data` 全体と
  `app/Plugin`（`.git` 抜き。remote は `plugins.txt`）を含む。favicon・納品書ロゴ・買った
  プラグインは git に無いので、ここでしか運ばれない。
  **`ECCUBE_AUTH_MAGIC` は全パスワードのハッシュの鍵。** 違う値で DB を戻すと誰も
  ログインできず、エラーも出ない。`restore.sh` が DB を戻す前に突き合わせて止める。
  引っ越しは「clone → `bin/init.sh` → AUTH_MAGIC を合わせる → `bin/restore.sh`」。
  **DB は MariaDB / MySQL か PostgreSQL**（`.env` の `DB_ENGINE`。イメージは両方の拡張を持つ）。
  backup / restore はそれを見て mysqldump / pg_dump を使い分ける。外部 DB でも同じ
  （`db` サービスが無ければ同じ DB のクライアントを使い捨てコンテナで起動し `.env` の `DB_*` で繋ぐ）。
  **ダンプは種類をまたいで戻らない**ので、引っ越し先も同じ `DB_ENGINE` にする。
  **`BACKUP_SYNC`** で外へ送る。送れなければ失敗にする（黙って飛ばすと「取れているつもり」になる）。
  **`BACKUP_ENCRYPT_KEY`** があれば全ファイルを AES-256 で暗号化して平文を残さない（DB ダンプは
  個人情報そのもの。#118）。`restore.sh` は `.enc` を見て同じ鍵で復号する。鍵を失うと全世代が
  読めなくなるので、鍵は `.env` とパスワードマネージャの両方に。
  **本番で管理画面が書いたファイルはそのサーバーにしか無い。** `doctor` と `backup.sh` が
  未コミット分を挙げる。
- **`.env` はアプリのコンテナに丸ごと渡さない。** 渡るのは `compose.yaml` の
  `x-eccube-environment` に列挙したものだけ（`DB_ROOT_PASSWORD` / `TUNNEL_TOKEN` /
  `BACKUP_SYNC` をアプリに乗せないため。#107）。EC-CUBE の任意設定は `.env.app`
  （`env_file` の `required: false`）。**空文字を `environment` で注入しない**
  （Symfony Dotenv が「設定済み」と見て本体の既定値を潰す）ので、任意のものは
  列挙せず `.env.app` に逃がす。`DB_PASSWORD` / `DB_ROOT_PASSWORD` / `ECCUBE_AUTH_MAGIC`
  は `:?` で必須（既定値 `eccube_pass` で黙って立ち上がらない。#110）。
- **`bin/reset.sh` と `bin/switch-version.sh` は `down -v` する。** DB・画像・
  セッションが消え、**その場では戻せない。** 稼働中が本番構成なら
  `CONFIRM_DESTROY=<プロジェクト名>` が無いと止まる（`bin/lib/guard.sh`）。
  **停止中は判定できない**ので、止まっている本番で打てば消える。
  上げたいだけなら `upgrade.sh`。詳細は `docs/data-safety.md`。
- **本番を上げるときは `bin/upgrade.sh <制約> --prod`。** `--prod` を落とすと
  `compose.override.yaml`（開発用のポートと bind mount）が効いた状態で公開される。
  **画面は出るので気づきにくい。** 稼働中なら自動でも寄せるが、停止中に打つと効かない。
- **compose ファイルの並びは `.env` の `COMPOSE_FILE` が正。`-f` を直書きしない。**
  PostgreSQL（`DB_ENGINE=postgresql`）は `compose.postgresql.yaml` を重ねる必要があり、
  `bin/init.sh` がそれを `COMPOSE_FILE` に書く。`docker compose -f a -f b` と直書きすると
  **`COMPOSE_FILE` は無視される**ので、その場所だけ MariaDB が立つ。**本番だけそうなっていた**
  （`upgrade` / `publish` / `deploy` が直書きだった）。`bin/lib/compose.sh` の
  `compose_files [--prod]` が `.env` の並びを読んで prod の出し入れだけをする。
- **IDE がライブラリを未定義と言うのは正常。** 本体と `vendor` はボリュームの中だけにあり
  ホストには1ファイルも無い。`bin/ide-sync.sh` で `.ide/` へ写し、PhpStorm の
  **Include Path**（ソースルートではない）に足す。リモートインタプリタを設定しても
  解決しない。バージョンを切り替えたら写し直す。
- **framework 級設定（monolog 等）は `app/config/eccube/packages/`**。entrypoint が起動時に
  本体の `app/config/eccube/packages/` へマージする（既定は消さない）。
  **切り替えたいものは `app/config/eccube/optional/<名前>/`** に置く。`packages/` は常に
  入るので、Redis のように「無い環境では 500 になる」設定を置くと初回から壊れる。
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
  - **キャッシュの組み立ては数分かかる。止めないこと。** 途中で止めると
    コンパイル済みコンテナが消えたまま残り、**全ページが 500 になる。**
    実際にそれでサイトを落とした。`warm_cache()` は始める前に一行出すので、
    黙っていても動いている。
  - **この種のコマンドの出力をパイプに通さない。** `docker compose exec ... | tail`
    のように読み手を挟むと、その読み手を先に止めたときコンテナの中の php が
    書き込みでブロックし、**終わったように見えて終わらない。** 固まったと
    誤解して強制終了 → キャッシュが壊れる、という道をたどる。ファイルへ
    落として、必要なときだけ読む。
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
  テストだけ同期送信。詳細は `docs/testing.md`。
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
- **Redis と Messenger は任意で、初回は無効。** スイッチは `.env` の `COMPOSE_PROFILES`
  一本（`redis` / `messenger`）。サービスの起動（profiles）と設定の投入
  （`app/config/eccube/optional/<名前>/` を entrypoint が `packages/` へ入れる／外す）が
  同じ値で決まる。**別々にすると「設定だけ入って Redis が居ない → 500」「worker だけ
  居なくてメールが DB に溜まる（エラーなし）」が黙って起きる。** `docker compose --profile`
  の CLI 指定は entrypoint に届かないので、必ず `.env` に書く。`doctor` が食い違いを見る。
  **redis を切り替えた瞬間、全員ログアウトになる。**
- **性能/スケール（Tier 1）**: php-fpm は `.env` の `PHP_FPM_*`、OPcache は entrypoint が
  `APP_ENV` で切替、Redis 共有キャッシュは `optional/redis/redis_cache.yaml`（任意）、DB は
  `docker/mariadb/conf.d/`、nginx は gzip/静的キャッシュ済み。詳細は `docs/scale.md`。
- **セッション Redis 共有（Tier 2）**: 専用 `redis-session` に保存し複数ホストで共有。
  本体の SameSite ハンドラは維持し内側だけ `Customize\Session\RawRedisSessionHandler` に
  差し替え（`optional/redis/redis_session.yaml`、`SESSION_REDIS_URL`）。
- **アップロード画像（Tier 2）**: `html/upload` は専用ボリューム `eccube_upload` に分離。
  複数ホストは NFS/EFS ドライバに差し替えて共有。`down -v`（reset/switch-version）で
  ローカルデータは消えるので事前バックアップ。詳細は `docs/scale.md`。
- **複数ホスト + LB（Tier 2）**: 各アプリホストは `compose.app.yaml`（db/redis を含まない
  app 層のみ、外部共有サービスを参照）。init ロール 1 台だけ `ECCUBE_SKIP_DB_INIT=0` で
  migrate、他は 1。HTTPS 終端 LB では `TRUSTED_PROXIES` 必須（本体未配線を
  `app/config/eccube/packages/trusted_proxies.yaml` で補う）。LB 例は `docker/nginx/lb.conf.example`。

## ドキュメントの置き場所

**README は入口だけ。** 設計方針・ディレクトリ・必要環境・クイックスタートまでで、
以降は `docs/` に分けてある。**README に長文を足さないこと。**

| 文書 | 中身 |
|---|---|
| `docs/handbook.md` | 初心者向け。理由を書かず手順だけ。毎日の 3 コマンドと困ったときの 1 コマンド |
| `docs/install.md` | 利用者向けの導入手順（取得 → 起動 → 更新の受け取り） |
| `docs/customize.md` | 本体を汚さずに実装を足す場所、framework 級設定 |
| `docs/upgrade.md` | バージョン切替とバージョンアップ、切り戻し |
| `docs/deploy.md` | 本番デプロイ |
| `docs/distribute.md` | 配布と更新（配布イメージ、`bin/self-update.sh`） |
| `docs/backup.md` | バックアップ / 復元 |
| `docs/data-safety.md` | `down` と `down -v` の違い、消えるコマンド、復旧 |
| `docs/scale.md` | 大規模アクセス、セッション・画像の共有、LB、メールの非同期化 |
| `docs/monitoring.md` | 監視 |
| `docs/testing.md` | ユニットテスト |
| `docs/ide.md` | PhpStorm の設定 |

## よく使う操作

```bash
bin/init.sh                    # 初回セットアップ
bin/deploy.sh                  # 自分のコードを反映。退避→メンテ ON→pull→migration→proxy→
                               # キャッシュ→疎通→OFF。失敗したら ON のまま止まる（壊れた画面を出さない）
bin/self-update.sh             # この環境自体を新しいリリースへ（--check で確認だけ）
bin/upgrade.sh ~4.3.2          # バージョンアップ（データ保持・運用環境向け）
bin/upgrade.sh ~4.3.2 --prod   # 本番はこちら。付けないと開発構成のまま公開される
bin/switch-version.sh ~4.2.0   # バージョン切替（データ破棄・開発用）
bin/reset.sh                   # DB 初期化
bin/publish.sh                 # 本番構成で起動（起動するだけ。本体の入れ替えはしない）
bin/console.sh <cmd>           # bin/console をコンテナの中で実行（www-data 固定）
                               # migration は --namespace=CustomizeMigrations を自動で補う
bin/shell.sh                   # コンテナに入る（既定 ec-cube・www-data）
bin/shell.sh db                # 他のサービス。--root で root

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
