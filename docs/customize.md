# カスタマイズ

EC-CUBE 本体を汚さずに独自の実装を足す場所と、その決まり。


- **PHP**（Controller / Entity 拡張 / Form / Service / Event / Twig 拡張 / Command）は
  `app/Customize/`（`Customize\` 名前空間）。テンプレート上書きは `app/template/`、
  スキーマ変更は `app/DoctrineMigrations/`。
- **プラグイン** は `app/Plugin/`。dev では rw マウントなので生成・導入・開発できる。
  自作プラグイン（private GitHub 等）は `bin/plugin.sh` でサクッと回せる:
  ```bash
  bin/plugin.sh add git@github.com:you/MyPlugin.git   # clone→install→enable
  bin/plugin.sh list                                  # 導入状況（enabled/version）
  bin/plugin.sh update MyPlugin                        # git pull→update→キャッシュ一掃
  bin/plugin.sh reload                                 # PHP/config 変更後のキャッシュ一掃
  bin/plugin.sh watch                                  # 変更を見張って自動で reload
  bin/plugin.sh remove MyPlugin                        # uninstall＋ディレクトリ削除
  bin/plugin.sh doctor                                 # システムエラーが出たときの点検と修復
  ```
  - private repo の認証は**ホスト側の git/SSH をそのまま使う**（コンテナに鍵を渡さない）。
  - **プラグインの置き場所は `app/Plugin/<Code>/` で、`<Code>` は `composer.json` の
    `extra.code` と完全一致が必須**（大文字小文字も区別。`Plugin\<Code>\` 名前空間に対応）。
    `bin/plugin.sh add` は `extra.code` を読んで自動でこの名前に配置するので、**GitHub の
    repo 名は無関係**（例: repo `my-awesome-plugin` → `extra.code=MyAwesomePlugin` なら
    `app/Plugin/MyAwesomePlugin/`）。手動で `git clone` する場合は clone 先を code に合わせる:
    ```bash
    git clone git@github.com:you/my-awesome-plugin.git app/Plugin/MyAwesomePlugin
    ```
  - 導入したプラグインは各自の repo で管理する前提で、eccube-docker 側の git には追跡させない
    （`.gitignore` で `app/Plugin/*` 除外済み）。
  - **開発を速く回すコツ**: `.env` を `APP_ENV=dev` にすると Twig/テンプレート変更は即反映。
    PHP・サービス・config を変えたら `bin/plugin.sh reload`。
  - **本番モードでは `cache:clear` だけでは変更が反映されない。** `var/cache` の外に
    2 種類のキャッシュが残る。`bin/plugin.sh` の各コマンドはどちらも消す。

    | 残るもの | 症状 |
    |---|---|
    | キャッシュプール（Redis 上の Doctrine メタデータ） | `Class Eccube\Entity\Product has no association named groups` で 500 |
    | OPcache（`opcache.validate_timestamps=Off`） | 更新したはずのコードが読まれない。プラグインコードを変えた直後の `Trait Plugin\...\XxxTrait not found` など |

    **OPcache は CLI では無効**なので、`bin/console` からは正常に見える。
    「コマンドは通るのにブラウザだけ壊れる」という切り分けにくい状態になる。
    手で消すなら:
    ```bash
    bin/console.sh cache:clear --no-warmup
    bin/console.sh cache:pool:clear --all
    docker compose exec ec-cube bash -c 'kill -USR2 1'   # php-fpm を graceful reload
    ```
  - **本番モードでは「キャッシュが古い」こと自体はエラーにならない。** 上の表はエラーが
    出るぶんまだ気づけるほうで、いちばん厄介なのは**足したサービスやタグだけが、例外も
    500 も出さずに効かない**形。画面は 200 で開き、ログにも何も出ず、ソースを読んでも
    テストを流しても正しいままなので、キャッシュを疑うまで見つからない。
    `git pull` でプラグインを更新した直後が特に危ない（ファイルだけ新しくなる）。

    ```bash
    bin/plugin.sh doctor   # コンパイル済みコンテナより新しいファイルがあれば挙げる
    bin/plugin.sh watch    # 見張って自動で reload。開発中は別のターミナルで放っておく
    ```

    切り分けるときは `var/cache/prod/Container*/get<サービス名>Service.php` を読んで、
    期待した定義が焼かれているかを見るのが速い。
  - **`docker compose` のプロジェクト名がずれていると、直したつもりで直らない。**
    `compose.yaml` の `name:` と別名でスタックを起動していると、`bin/*.sh` は `name:` の
    ほうへ行く。**止まっているスタックにも `exec` は通る**ので、reload も doctor も
    成功したように見えてブラウザは古いまま。`.env` に `COMPOSE_PROJECT_NAME=<稼働中の名前>`
    を書いて固定し、使わないスタックは落としておく（同じ `app/` を bind-mount した
    二重起動は `app/proxy/entity` を奪い合う）。
  - **`eccube:plugin:install` / `enable` / `disable` を手で叩くときは、前後のキャッシュ操作を
    忘れないこと。** `doctrine.yaml` の `auto_generate_proxy_classes` は `%kernel.debug%`
    （prod では false）で、Doctrine のプロキシはキャッシュウォーマーでしか作られない。
    本体のプラグインコマンドは内部で `cache:clear --no-warmup` までしかやらない。

    | 抜けたもの | 症状 |
    |---|---|
    | **前**の `cache:pool:clear --all` | `Property Eccube\Entity\Product::$BundleItems does not exist` でコマンドが異常終了。`var/cache` を消しても直らない（実体は Redis 側） |
    | **後**の warmup 込み `cache:clear` | トレイトで足した getter が例外も出さずに空のコレクションを返す。`findBy()` は件数を返すのに `$Product->getBundleItems()` は 0 件になり、Processor が黙って何もしない |

    ```bash
    bin/console.sh cache:pool:clear --all
    bin/console.sh eccube:plugin:enable --code=MyPlugin
    bin/console.sh cache:clear   # --no-warmup を付けない
    ```

    `bin/plugin.sh` の各コマンドはこれを両方やるので、基本はそちらを使えばよい。
  - **プラグイン操作のあとにシステムエラーが出たら `bin/plugin.sh doctor`。** 中断した
    操作は痕跡を残す。よくあるのは次の 3 つで、どれも「操作したプラグインとは別の場所」が
    壊れるので原因にたどり着きにくい。

    | 残るもの | 症状 |
    |---|---|
    | `.maintenance`（管理画面からの操作が立てる `auto_maintenance`） | **フロントだけ 503**。管理画面は素通りできるので気づきにくい |
    | 書きかけのコンパイル済みコンテナ | 全ページ 500（`Failed opening required '.../var/cache/prod/ContainerXXXX/...'`） |
    | `dtb_plugin.enabled` が 0 に落ちたプラグイン | 拡張プロパティを前提にした**別の画面**が落ちる（`Property Plugin\...\Group::$optionEntry does not exist` など） |

    `doctor` は残骸の掃除・無効プラグインの検出・エンティティ拡張の反映確認・キャッシュの
    組み立て直し・主要ページの疎通確認までやる（手動で入れたメンテナンスは解除しない）。
    なお prod では `app/config/eccube/packages/prod/doctrine_proxy.yaml` で
    `auto_generate_proxy_classes: 2`（無いものだけ生成）にしてあり、プロキシが欠けた
    状態でも致命エラーにならない。
  - スケルトン生成は従来どおり:
    ```bash
    bin/console.sh eccube:plugin:generate "My Plugin" MyPlugin 1.0.0
    ```
- **デザイン（CSS/JS）** は `html/user_data/assets/{css,js}`。本体の `default_frame.twig` が
  `customize.css` / `customize.js` を（`style.css` の後に）自動読込するので、上書き Twig は不要。
  scss ソースは `frontend/scss/`、ビルドは:
  ```bash
  bin/assets.sh build        # 一括ビルド → html/user_data/assets/css/customize.css
  bin/assets.sh watch        # 監視ビルド（dev の node サービス。保存で自動）
  ```
  本体テーマ（`html/template/default` など）を丸ごと作り替えたいときだけ、純正
  Gulp/Webpack を回す `bin/assets.sh core-build`（＝本体直編集・Git 管理外・データ破棄で戻る）。

# framework 級設定（monolog 等）の置き場所について

EC-CUBE 4.3 の `src/Eccube/Kernel.php::configureContainer()` は、
`app/config/eccube/packages/*.yaml` と `app/Customize/Resource/config/services.yaml` を
**同じ `$loader`・同じコンテナビルド（extension 処理）フェーズ**で読み込む。よって
`monolog:` 等の framework 級キーは **どちらのファイルに書いても拾われる**。

本テンプレートでは、DI 設定（services.yaml）と framework 級設定を分離する方針で
`app/config/eccube/packages/logging.yaml` に置いているだけで、技術的な制約ではない。

> この点は本環境で実証済み。`packages/` から `monolog:` を外し、
> `app/Customize/Resource/config/services.yaml` にだけ書いた状態で
> `bin/console debug:container monolog.logger.<channel>` がサービスを解決した。

## コンテナの中に入る

```bash
bin/shell.sh              # ec-cube に www-data で入る（既定）
bin/shell.sh --root       # ec-cube に root で入る
bin/shell.sh db           # 他のサービス（db / redis / nginx / node ...）
bin/shell.sh db --root
```

**既定を www-data にしてあるのは事故を避けるため。** root のまま `bin/console` や
composer を打つと `var/cache` と `var/log` に root 所有のファイルができ、そのあと
php-fpm（www-data）が書けなくなって**全ページ 500** になる。root が要るのは
パッケージの導入や php-fpm への USR2 送信など限られた場面だけ。

`www-data` を持たないイメージ（db / redis / nginx）には `-u` を渡さない。渡すと
「unable to find user」で入れない。`nginx` と `redis` は alpine なので `bash` が
無く、`sh` に切り替える。ラッパーがどちらも見て決める。

**コンテナが止まっていると `exec` は通らない。** そのときは使い捨てのコンテナで
入る（ラッパーが自動で切り替え、その旨を表示する）。

```bash
docker compose run --rm --no-deps ec-cube bash
```

アップグレードに失敗してサイトが落ちているときはこちら。`bin/backup.sh` が画像を
取るのに `run` を使っているのも同じ理由。

素の形も残しておく。

```bash
docker compose exec ec-cube bash                  # root
docker compose exec -u www-data ec-cube bash      # www-data
docker compose exec db mysql -u root -p           # そのまま SQL
docker compose exec redis redis-cli               # Doctrine のメタデータ
docker compose exec redis-session redis-cli       # セッション
```

## migration を作る

**独自の migration はホストの `app/DoctrineMigrations/` に置く。**

```bash
bin/console.sh doctrine:migrations:generate
```

`bin/console.sh` が `--namespace=CustomizeMigrations` を補う。開発では
ホストへ rw で mount してあるので、**生成されたファイルはそのまま手元に出る**
（Git 管理下）。

**素の `bin/console` で `--namespace` を省くと本体側に作られる。** そちらは
イメージの中なので、**ホストには現れず、次のビルドで消える。** その場では
動くので気づきにくい。

置き場所がねじれているのは意図的で、

| | |
| --- | --- |
| ホスト `app/DoctrineMigrations/` | 自分で書くもの |
| コンテナ `app/CustomizeMigrations` | 上の mount 先 |
| コンテナ `app/DoctrineMigrations` | **本体同梱の 18 件**（触らない） |

同じパスへ mount すると本体分を覆い隠すため、別名で載せて両方を登録している
（`app/config/eccube/packages/doctrine_migrations.yaml`）。

**`--diff` は勧めない。** 本体のスキーマは migration ではなくエンティティ定義が
持っている（本体 migration に `CREATE TABLE` も `ALTER TABLE` も 1 件も無い）ので、
diff を取ると本体の差分まで拾う。`up()` / `down()` は手で書く。

流すとき:

```bash
bin/console.sh doctrine:migrations:migrate
bin/console.sh doctrine:migrations:status
```

**Linux ホストでは所有者が www-data になることがある。** 手元で編集できない
ときは `sudo chown $(id -u):$(id -g) app/DoctrineMigrations/Version*.php`。

**プラグインでは基本は要らない。** エンティティ拡張とトレイトで列を足し、テーブルの
作成は本体のプラグイン機構に任せる。migration が要るのは既存データの移行だけ。

---

[← README へ戻る](../README.md)
