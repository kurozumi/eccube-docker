# eccube-docker

EC-CUBE 4 を **どのサーバー（各社 VPS / AWS など）でも同じ手順で** インストール〜公開
できる、汎用の Docker 環境。`git clone && bin/init.sh` で開発環境が立ち上がる。

## 設計方針

- **EC-CUBE 本体はイメージにベイクする**（`docker/php/Dockerfile` の `composer create-project`）。
  リポジトリには含めない。→ **バージョン切替 = イメージ再ビルド**。
- **本体は汚さない**。Git 管理するのは *自分のコードだけ*。名前付きボリューム
  `eccube_app` に展開した本体の上に、必要なディレクトリだけを bind-mount で重ねる。

  | ホスト | → コンテナ | 用途 |
  |---|---|---|
  | `app/Customize/` | `app/Customize` | DI・独自ロジック（開発は rw） |
  | `app/template/` | `app/template` | テーマ・テンプレート上書き（開発は rw） |
  | `app/DoctrineMigrations/` | `app/CustomizeMigrations` | 独自マイグレーション（開発は rw）。本体同梱の `app/DoctrineMigrations` を隠さないため別パスへ載せる |
  | `app/Plugin/` | `app/Plugin` | プラグイン（開発は rw、生成・導入可） |
  | `app/config/eccube/packages/` | 同左（entrypoint がマージ） | monolog / cache / trusted_proxies 等の framework 級設定 |
  | `html/user_data/` | `html/user_data` | 独自 CSS/JS（本体が自動読込。ec-cube/nginx/caddy へ） |

  アップロード画像（`html/upload`）は bind ではなく**専用ボリューム `eccube_upload`**
  （NFS/EFS に差し替え可）。詳細は「アップロード画像の共有ストレージ」節。

- **本体の migration はイメージの `app/DoctrineMigrations/` に同梱されている**（18 件・
  すべてデータ移行）。ここへホストのディレクトリを直接 bind-mount すると本体分を
  覆い隠してしまうので、*自分で書く* migration はコンテナ内の `app/CustomizeMigrations/`
  へ載せ、両方を doctrine に登録している
  （`app/config/eccube/packages/doctrine_migrations.yaml`）。
  **ホスト側の置き場所は従来どおり `app/DoctrineMigrations/`** で変わらない。

## ディレクトリ

```
.
├── compose.yaml            # base（ec-cube / worker / nginx / db / redis / redis-session）
├── compose.override.yaml   # 開発用（自動読込: Mailpit・phpMyAdmin・node・rw マウント）
├── compose.prod.yaml       # 本番用（-f で指定。公開層をプロファイルで選択）
├── compose.app.yaml        # 複数ホスト用: app 層のみ（DB/Redis は外部共有を参照）
├── .env.example
├── .github/workflows/build-image.yml   # CI: GHCR へイメージ build & push
├── app/                    # ← Git 管理する「自分のコード」
│   ├── Customize/
│   │   ├── Command/MailTestCommand.php     # customize:mail-test（メール疎通確認）
│   │   ├── Resource/config/services.yaml   # DI（Redis セッション差し替え等）
│   │   └── Session/RawRedisSessionHandler.php
│   ├── template/
│   ├── DoctrineMigrations/
│   ├── Plugin/             # プラグイン（開発・ストア導入）
│   └── config/eccube/packages/   # logging / cache / trusted_proxies / messenger
│       └── test/messenger.yaml   # テストだけメール同期送信（後述）
├── frontend/               # 独自テーマの Sass ソース
│   ├── package.json        # Dart Sass ビルド定義
│   └── scss/customize.scss
├── html/user_data/         # 独自 CSS/JS（本体が自動読込）
│   └── assets/{css/customize.css, js/customize.js}
├── docker/
│   ├── php/{Dockerfile,php.ini,www-pool.conf.tmpl,docker-entrypoint.sh}
│   ├── nginx/{default.conf,lb.conf.example}
│   ├── mariadb/conf.d/eccube.cnf
│   └── caddy/Caddyfile
└── bin/{init,upgrade,switch-version,reset,publish,healthcheck,assets,plugin,test,backup,restore}.sh
```

## 必要環境

- Docker Engine / Docker Compose v2.24 以上（`compose.prod.yaml` で `!override` を使用）
- amd64 / arm64 どちらも可

## クイックスタート（開発）

```bash
git clone <this-repo> eccube-docker && cd eccube-docker
bin/init.sh                       # .env 作成・AUTH_MAGIC 生成・build & up
docker compose logs -f ec-cube    # 初回は EC-CUBE 取得と install で数分
```

| 用途 | URL |
|------|-----|
| フロント | http://localhost:8080/ |
| 管理画面 | http://localhost:8080/admin/ |
| Mailpit UI | http://localhost:8025/ |
| phpMyAdmin | http://localhost:8081/ |

既定は本番モード（`.env` の `APP_ENV=prod`）。デバッグしたいときだけ `.env` を
`APP_ENV=dev` / `APP_DEBUG=1` にして `docker compose up -d`。

## カスタマイズ（本体を汚さず Git 管理）

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
  bin/plugin.sh remove MyPlugin                        # uninstall＋ディレクトリ削除
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
  - 導入したプラグインは各自の repo で管理する前提で、docker-eccube 側の git には追跡させない
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
    docker compose exec ec-cube runuser -u www-data -- php bin/console cache:clear --no-warmup
    docker compose exec ec-cube runuser -u www-data -- php bin/console cache:pool:clear --all
    docker compose exec ec-cube bash -c 'kill -USR2 1'   # php-fpm を graceful reload
    ```
  - スケルトン生成は従来どおり:
    ```bash
    docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:generate "My Plugin" MyPlugin 1.0.0
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

## バージョン切替 / バージョンアップ

用途が違う 2 本がある。**運用中の店舗を上げるなら `upgrade.sh`**。

```bash
bin/upgrade.sh ~4.3.2          # データを保ったまま上げる（運用中の環境向け）
bin/switch-version.sh ~4.2.0   # データごと作り直す（開発で別バージョンを試す用）
```

|                    | DB・アップロード画像 | 用途                     |
| ------------------ | -------------------- | ------------------------ |
| `upgrade.sh`       | **残る**             | 運用中の環境を上げる     |
| `switch-version.sh` | 破棄される（`down -v`） | 開発で別バージョンを試す |

`switch-version.sh` は「指定バージョンをまっさらに立て直す」ツールで、バージョンアップ
ツールではない。**本番環境に使うと受注・会員データが消える。**

どちらも**破棄はビルドが通ってから行う**。先に `down -v` すると、新バージョンの取得や
依存解決に失敗したときにデータだけ消えて環境が残らない。ビルドが失敗した場合は `.env` の
`ECCUBE_VERSION` を元へ戻して終了し、稼働中の環境とデータには触れない。

### バージョンアップの手順

**本番でいきなり実行しない。** 本番のデータを写したステージングで一度通し、出たエラーを
潰してから本番に入る。`bin/upgrade.sh` は危険を検出すると止まるが、「止まらずに済む状態」
にする作業はステージングでやる。

#### 1. 事前確認

```bash
# いま動いている Symfony の世代（プラグイン互換性の判断材料）
docker compose exec ec-cube runuser -u www-data -- composer show symfony/framework-bundle

# 入っているプラグインの一覧
bin/plugin.sh list
```

- **プラグインの対応状況**を先に調べる（下の「プラグインの互換性」）。ここが一番詰まる
- **PHP のバージョン要件**を確認する。`bin/upgrade.sh` は `ECCUBE_VERSION` しか書き換え
  ないので、PHP を上げる必要があるなら `.env` の `PHP_VERSION` を手で変える
- **バックアップの保存先**がサーバー外にあるか確認する

#### 2. ステージングで予行演習

```bash
# 別ディレクトリに clone し、プロジェクト名とポートを分ける
git clone <this-repo> eccube-staging && cd eccube-staging
cp ../eccube-docker/.env .
#   .env を編集: COMPOSE_PROJECT_NAME=eccube-staging / HTTP_PORT=8090
bin/init.sh

# 本番のバックアップを流し込む（本物のデータで試すのが肝心）
bin/restore.sh ../eccube-docker/backups/<日時>

# 本番と同じプラグインを app/Plugin へ置いてから実行
bin/upgrade.sh ~4.4.0
```

エラーが出たら `app/Customize` / `app/template` / プラグインを直し、**ステージングを作り
直して最初から通す**。「通ったところから再開」だと直し漏れに気づけない。

#### 3. 本番で実施

```bash
# 告知してから（ダウンタイムが発生する）
bin/upgrade.sh ~4.4.0
```

完了後、最低でもこれだけは目視で確認する。

- フロントの表示・商品詳細・カート投入
- 管理画面のログイン・受注一覧・商品登録
- 決済まわり（決済プラグインを使っているなら特に）
- `docker compose logs ec-cube` にエラーが出ていないか

#### 4. 失敗したとき

`bin/upgrade.sh` は失敗した段階によって止まる場所が違う。

| 止まった場所 | 状態 | 対処 |
| ------------ | ---- | ---- |
| ビルド / 事前確認 | **稼働中の環境は無傷** | プラグインを直して再実行 |
| スキーマ差分の検査 | サイト停止・**DB は無傷** | 差分を確認し、原因のプラグインを直す |
| `schema:update` / `migrate` | サイト停止・DB は途中まで適用 | `bin/upgrade.sh <旧バージョン>` で戻し、必要なら `bin/restore.sh` |
| 起動確認 | 公開済みだが応答しない | ログを見る。だめなら上と同じ |

切り戻しは `.env` を戻すだけでは足りない。**本体コードを戻すために `bin/upgrade.sh <旧
バージョン>` を実行**し、DB を戻すなら `bin/restore.sh <バックアップ>` も要る。

### プラグインの互換性

**EC-CUBE のマイナーバージョンアップは、土台の Symfony の世代交代を伴うことがある。**
その場合、プラグインが継承しているクラスのシグネチャや、使っている Symfony の API が
変わるため、**旧バージョン向けのプラグインはそのままでは動かない**。

このリポジトリで実測した対応:

| EC-CUBE | Symfony | 備考 |
| ------- | ------- | ---- |
| 4.2 系 | 5.4 | 実測 |
| 4.3 系 | 6.4 | 実測 |

> 4.4 以降は未確認。上のコマンドで実際の値を見ること。世代が変わっていれば
> プラグインの改修が要ると考えてよい。

実際に 4.2 向けプラグインを 4.3 に載せると、こうなる（EC-CUBE 同梱のサンプル
プラグインで再現したもの）。

```
Fatal error: Declaration of Plugin\MigrationSample\PluginManager::install(
  array $meta, Symfony\Component\DependencyInjection\ContainerInterface $container
) must be compatible with Eccube\Plugin\AbstractPluginManager::install(
  array $meta, Psr\Container\ContainerInterface $container
)
```

4.3 で `AbstractPluginManager::install()` の型が `Symfony\...\ContainerInterface` から
`Psr\Container\ContainerInterface` に変わったため。**クラス宣言の互換性チェックで落ちる
ので、`bin/console` を使う処理はすべて巻き添えになる。**

`bin/upgrade.sh` はこれを **ビルド直後・`down` の前** に検出して中止する。新イメージと
ホストの `app/Plugin` / `app/Customize` だけでコンテナを起動し、クラスが読めるか試す。
止まった時点で稼働中の環境・DB・画像には一切触れていない。

対処:

| プラグインの出どころ | やること |
| -------------------- | -------- |
| オーナーズストア | 新バージョン対応版が出ているか確認する。無ければ**出るまでバージョンアップしない**か、代替を探す |
| 自作 | 自分で改修する。シグネチャ変更・非推奨 API の置き換えが中心 |
| もう使っていない | 無効化して外す（下記） |

使っていないプラグインを外す手順:

```bash
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:disable --code=Foo
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:uninstall --code=Foo
rm -rf app/Plugin/Foo
```

> **無効化しただけで列が残っていると `bin/upgrade.sh` が止まる。** プラグインが
> `EntityExtension` で足した列は、プラグインが無効だとエンティティ定義から消えるため
> `schema:update` の削除対象になるため。止まった場合は差分 SQL を見て、その列が本当に
> 不要か判断してから手で削除する。

### プラグインのデータは残るか

| 対象 | `bin/upgrade.sh` 後 |
| ---- | ------------------- |
| プラグイン独自テーブル（`plg_xxx`） | **残る** |
| `dtb_plugin` の有効状態・バージョン | **残る** |
| `app/Plugin/<Code>` のファイル | **残る**（bind-mount のため） |
| `EntityExtension` で足した列 | プラグインが**有効なら残る**。無効・非対応だと削除対象（検出して中止する） |
| ストア製プラグインの `composer.json` / `vendor/` | **消える**（`eccube_app` 側にあるため） |

最後の行が要注意。オーナーズストア経由のインストールは `composer require ec-cube/<code>`
を実行するため、composer の管理状態が `eccube_app` ボリュームに載る。**依存パッケージを
持つストア製プラグインは、バージョンアップ後に管理画面から入れ直す**こと。プラグイン本体
のファイルと DB のデータは残っているので、再インストールで元に戻る。

### bin/upgrade.sh の動き

1. `bin/backup.sh` を実行（失敗したら何も触らずに中止）
2. `.env` の `ECCUBE_VERSION` を更新してイメージをビルド（ビルド失敗時は `.env` を戻す）
3. `docker compose down`（`-v` なし）→ **`eccube_app` ボリュームだけ** 削除
4. 起動前に `var/.eccube_installed` を置く
5. **公開しないまま** DB を整合させる（`compose run` の使い捨てコンテナ。nginx は上げない）
   1. `doctrine:schema:update` — 差分 SQL を表示してから適用（DDL）
   2. `doctrine:migrations:migrate` — 本体 18 件のデータ移行
6. `up -d` で公開

手順 3 が要る理由は、`eccube_app` が `/var/www/html` 全体を覆っているため、イメージを
作り直しても既存ボリュームがある限り新しい本体コードが反映されないから
（`docker/php/docker-entrypoint.sh` の `1b)` のコメント参照）。

手順 4 が要る理由は、`eccube_app` を作り直すとマーカーが消え、entrypoint が「未インストール」と
誤判定して**データの入った既存 DB に `eccube:install` を撃ってしまう**ため。先にマーカーを
置くことで migration 経路へ寄せる。

手順 5 を**公開前**にやるのは、先に `up -d` すると新コードと旧スキーマが噛み合わない状態で
nginx が公開され、スキーマ更新が終わるまで全ページ 500 を返すため。`compose run` の
使い捨てコンテナは `ec-cube` の `depends_on`（db / redis / redis-session）しか連れて
こないので、nginx と worker を上げずに DB だけ整合させられる。

> それでも `down` から `up -d` までの**ダウンタイムそのものは無くならない**（接続断に
> なる）。無停止にしたいなら別系統を立てて LB で切り替える構成が要る。

手順 5 が 2 つに分かれているのは、**EC-CUBE 4.x のバージョンアップが 2 段構え**だから。

| 対象 | 正となるもの | 手段 |
| ---- | ------------ | ---- |
| DDL（カラム追加など） | エンティティ定義 | `doctrine:schema:update` |
| データ（マスタ追加・不整合の是正） | `app/DoctrineMigrations` の migration | `doctrine:migrations:migrate` |

本体の migration 18 件には `ALTER TABLE` / `CREATE TABLE` が **1 件も無い**（全てデータ
移行）。だから `migrate` だけではカラムが増えず、新しいエンティティが期待するカラムが
無くて全ページ 500 になる（4.2 → 4.3 なら `dtb_base_info.ga_id`）。逆に `schema:update`
だけではマスタデータが入らない。両方要る。

> 本体の migration は個々に存在チェックが入っているので、再実行しても二重適用にならない。

**`schema:update` は「エンティティ定義に無い列」を削除する。** `--complete` の有無は
関係ない（`--complete` 無しで削除を免れるのはテーブルだけで、既存テーブルに追加された
列は消える）。プラグインが `EntityExtension` で足した列（例: `dtb_customer.sort_no`）は、
その時点でプラグインが有効かつメタデータに載っていないと削除対象になる。

そのため `bin/upgrade.sh` は次の順で守っている。

1. `eccube:generate:proxies` — `eccube_app` を作り直すと `app/proxy/entity` が消えるので、
   有効なプラグインのエンティティ拡張をメタデータへ載せ直す
2. 差分 SQL に列・テーブルの削除が混じっていないか検査し、あれば**中止する**
   （`DROP INDEX` / `DROP FOREIGN KEY` / `DROP PRIMARY KEY` は索引の貼り直しなので除外）

意図的に削除を適用したいときだけ `UPGRADE_ALLOW_DROP=1 bin/upgrade.sh <version>`。

注意点:

- migration は前進のみ。**ダウングレードはできない。** 切り戻しは `.env` を戻して
  `bin/upgrade.sh <旧バージョン>` を実行し、必要なら `bin/restore.sh` で DB を書き戻す。
- マイナー/メジャーをまたぐ場合、既存プラグインが新バージョン非対応だと起動後にエラーに
  なりうる。事前に対応状況を確認すること。
- 完了後は管理画面・フロント・受注データを目視で確認すること。

複数バージョンを並行運用したい場合は、別ディレクトリに clone するか `.env` の
`COMPOSE_PROJECT_NAME` を分ける。

## 本番デプロイ（どのサーバーでも）

```bash
# .env で公開方式を選ぶ（COMPOSE_PROFILES）
bin/publish.sh   # docker compose -f compose.yaml -f compose.prod.yaml up -d --build
```

| プロファイル | 公開方式 | 開けるポート |
|---|---|---|
| `tunnel` | Cloudflare Tunnel（既定） | なし（outbound のみ） |
| `caddy` | Caddy 自動 HTTPS（Let's Encrypt） | 80 / 443 |
| （未設定） | host nginx / AWS ALB の背後 | なし（127.0.0.1 束縛） |

- **tunnel**: `.env` に `TUNNEL_TOKEN` を設定。ダッシュボードで公開ホスト名 → `http://nginx:80`。
- **caddy**: `.env` に `SITE_DOMAIN` を設定し、A レコードをこのサーバーへ向ける。
- **背後配置**: `COMPOSE_PROFILES` を空にすると nginx は `127.0.0.1:8080` のみで待ち受ける。

## 大規模アクセス / スケール

段階的にスケールできる構成になっている（すべて実機検証済み・本体は非編集）:

| 段階 | 内容 | 節 |
|---|---|---|
| Tier 1 | 単一ホスト強化（php-fpm / OPcache / Redis キャッシュ / DB / nginx） | この節 |
| Tier 1 | 1台内の水平スケール（`--scale` 内部ロードバランス） | 水平スケール |
| Tier 2 | セッションの Redis 共有 | セッションの Redis 共有 |
| Tier 2 | アップロード画像の共有ストレージ（NFS/EFS） | アップロード画像 |
| Tier 2 | 複数ホスト + 外部 LB（`compose.app.yaml`） | 複数ホスト + LB |

### 単一ホスト強化（Tier 1）

単一ホストのまま高トラフィックに耐えるための強化が入っている。

| 強化 | 場所 | 調整 |
|---|---|---|
| php-fpm ワーカー数 | entrypoint が env から生成 | `.env` の `PHP_FPM_*` |
| 本番 OPcache（`validate_timestamps=0`） | entrypoint（`APP_ENV=prod` で自動） | — |
| Redis 共有キャッシュ（Symfony app cache） | `redis` サービス＋`app/config/eccube/packages/cache.yaml` | `REDIS_URL` |
| MariaDB バッファプール等 | `docker/mariadb/conf.d/eccube.cnf` | `innodb_buffer_pool_size` を RAM に合わせる |
| gzip / 静的長期キャッシュ | `docker/nginx/default.conf` | — |

**まず調整すべき2点**: `PHP_FPM_MAX_CHILDREN`（＝同時処理数。メモリから算出）と
`innodb_buffer_pool_size`（＝専用 DB なら RAM の 50〜70%）。

**DB 接続数の設計式**（特に複数ホスト時）:

```
Σ(各ホストの PHP_FPM_MAX_CHILDREN) + worker 数 + 管理用余裕(10〜20) ≦ max_connections(既定 200)
```

例: `MAX_CHILDREN=50` を 4 ホスト並べると 200 で即枯渇（Too many connections）。
`docker/mariadb/conf.d/eccube.cnf` の `max_connections` を上げるか、ホストあたりの
children を配分する。

### 水平スケール（1台の中で php-fpm を増やす）

```bash
docker compose up -d --scale ec-cube=3
```

nginx は Docker 内蔵 DNS を毎回引き直して各レプリカへ分散する（内部ロードバランス）。
実測で 2 レプリカに約 11:9 で振り分き、1 台停止時も残りが 200 を返し継続（フェイルオーバー）。

注意点:
- レプリカは同じ `eccube_app` ボリューム（`var/cache`）を共有するため、追加レプリカの
  起動時 `cache:clear` が稼働中レプリカのコンパイル済みキャッシュを一瞬消して 500 を
  出し得る。**スケール追加時はスキップフラグを付けて起動**する:
  ```bash
  ECCUBE_SKIP_DB_INIT=1 ECCUBE_SKIP_CACHE_CLEAR=1 docker compose up -d --scale ec-cube=3 --no-recreate
  ```
  （migrate / cache:clear は 1 台目が起動時に済ませている。追加分は何も触らない）
- `docker compose up` を `--scale` なしで実行すると台数が既定(1)に戻る。スケール状態を
  保つなら毎回 `--scale ec-cube=N` を付けるか、`deploy.replicas` を設定する。

## セッションの Redis 共有（Tier 2）

セッションは専用の `redis-session` サービス（永続化・`noeviction`）に保存される。
これにより **複数ホスト／複数レプリカでセッションが共有**され、ボリューム共有に依存せず
カート・ログインが保たれる（LB を前に置いても成立する）。

- 本体の `SameSiteNoneCompatSessionHandler`（決済リダイレクトの SameSite=None 対応）は
  維持したまま、その内側のハンドラだけを `Customize\Session\RawRedisSessionHandler` で
  Redis に差し替えている（`app/Customize/Resource/config/services.yaml`）。
- 接続先は `.env` の `SESSION_REDIS_URL`（本番はマネージド Redis に向けられる）。
- キャッシュ用 `redis`（`allkeys-lru`）とは別インスタンスにして、セッションが LRU で
  勝手に消えないようにしている。上限は `.env` の `SESSION_REDIS_MAXMEMORY`（既定 256mb）。
  到達時は OOM ではなく新規セッションの書込エラーになり、既存ユーザーは守られる。
- 単一ホストのみで運用するなら不要。この 3 定義（services.yaml）と `redis-session`
  サービスを外せばファイルセッションに戻る。

> 実測: ログイン系ページで発行される `eccube` セッション ID が `redis-session` に
> `ecses:<id>`（TTL≈`gc_maxlifetime`）として保存され、`--scale=2` でも両レプリカから
> 同一セッションを参照できることを確認済み。`var/sessions` には新規作成されない。

> 既知の挙動: Redis セッションは**非ロック**（同一セッションの同時リクエストは後勝ち）。
> これは Symfony 標準の RedisSessionHandler と同じ挙動で、通常のブラウジングでは
> 問題にならない（Ajax 多重発行等で稀にカート更新が競合し得る程度）。

## アップロード画像の共有ストレージ（Tier 2）

商品画像などのアップロードは `html/upload`（`save_image` / `temp_image`）に保存される。
これを **専用ボリューム `eccube_upload`** に分離してあり、アプリ（`eccube_app`）や DB とは
独立している。複数ホストで LB する場合、**あるホストで登録した画像を別ホストも見られる**
必要があるため、このボリュームを共有ストレージに向ける。

**複数ホスト共有（NFS の例）** — `compose.yaml` の `volumes:` を差し替える:

```yaml
volumes:
  eccube_upload:
    driver: local
    driver_opts:
      type: nfs
      o: "addr=10.0.0.10,rw,nfsvers=4"
      device: ":/export/eccube/upload"
```

AWS なら EFS を同様に指定する。**外部ストレージ側にデータがあるので、`down -v` でも
実データは失われない**（ローカルボリュームのままだと `down -v`＝`reset`/`switch-version`
で消える）。

**バックアップ / 移行**（ローカルボリューム運用時）:

```bash
docker compose cp ec-cube:/var/www/html/html/upload/. ./upload-backup/   # 退避
docker compose cp ./upload-backup/. ec-cube:/var/www/html/html/upload/   # 復元
```

> オブジェクトストレージ（S3 直結）にしたい場合は、EC-CUBE 側に S3 アダプタ（プラグイン
> またはサービス上書き）と画像配信の URL 変更が必要で、バージョン依存が大きい。まずは
> 本体無改造で済む共有ファイルシステム（NFS/EFS）方式を推奨。

## 複数ホスト + ロードバランサ

これまでの強化でアプリ層はステートレス（セッション/キャッシュ=Redis、画像=共有ストレージ、
DB=外部）になっているので、**アプリホストを N 台並べて前段に LB** を置ける。

### 構成

```
            ┌─ 外部 LB（HTTPS 終端 / nginx・Cloudflare LB・ALB）
            │        │ 振り分け
   ┌────────┴──┐  ┌──┴────────┐
   │ app host1 │  │ app host2 │  … 各ホストで compose.app.yaml（ec-cube+nginx）
   └────┬──────┘  └────┬──────┘
        └──────┬───────┘  すべて同じ外部サービスを参照
        共有: DB / Redis(cache) / Redis(session) / アップロード画像(NFS/EFS)
```

### 手順

1. **共有サービスを用意**（別ホスト or マネージド）: DB、Redis（キャッシュ）、Redis
   （セッション）、アップロード用 NFS/EFS。
2. **各アプリホスト**で `compose.app.yaml`（db/redis を含まない app 層のみ）を起動:
   ```bash
   docker compose -f compose.app.yaml up -d --build   # 本番は push 済み image 推奨
   ```
   `.env` に外部エンドポイント（`DB_HOST` / `REDIS_URL` / `SESSION_REDIS_URL`）と
   `TRUSTED_PROXIES=<LB の IP/サブネット>` を設定する。
3. **スキーマ移行は 1 台だけ**: どこか 1 台を `ECCUBE_SKIP_DB_INIT=0` で起動して
   `migrate` を済ませ、以降の app ホストは `ECCUBE_SKIP_DB_INIT=1`（既定）で起動する
   （全台が一斉に migrate すると競合するため）。
4. **前段の LB**:
   - 自前 nginx: `docker/nginx/lb.conf.example` を参照（`upstream` に各 app ホストを列挙）。
   - Cloudflare Load Balancing: 各 app ホスト（の nginx:80/443）をオリジンプールに登録。
   - AWS ALB: ターゲットグループに各 app ホストを登録。ヘルスチェックは `/`。

> **重要**: LB で HTTPS を終端する場合、各アプリホストの `.env` に `TRUSTED_PROXIES` を
> 設定し、LB は `X-Forwarded-Proto` を送ること。これが無いと EC-CUBE が HTTPS を認識できず、
> セッション Cookie の `secure`/`SameSite=None` が付かず（決済で問題）、生成 URL も http に
> なる。セッションは Redis 共有なので **スティッキーセッションは不要**。

### デプロイ / 更新（CI とローリング更新）

**イメージは CI が 1 回だけ build** し、各ホストは pull する（全ホスト同一の保証）。

- `.github/workflows/build-image.yml`: main への push（`docker/php/**` 変更時）で
  `ghcr.io/<owner>/<repo>/ec-cube:latest` と `:<git-sha>` を push。手動実行では
  `ECCUBE_VERSION` を指定できる。認証は `GITHUB_TOKEN`（追加シークレット不要）。
- 各アプリホストの `.env` に `ECCUBE_IMAGE=ghcr.io/<owner>/<repo>/ec-cube:<sha>` を設定
  （`latest` より **sha 固定を推奨**。ロールバック = 前の sha に戻して pull）。

**ローリング更新**（無停止。1 台ずつ）:

```bash
# ホスト A で（他ホストは稼働継続）
# 1. LB からホスト A を外す（nginx LB: upstream をコメントアウトして reload /
#    Cloudflare LB: プールで無効化 / ALB: deregister）
# 2. 新イメージへ更新
docker compose -f compose.app.yaml pull ec-cube
docker compose -f compose.app.yaml up -d --no-build
# 3. ヘルス確認（healthy になるまで）
docker compose -f compose.app.yaml ps
curl -fsS http://localhost:8080/ -o /dev/null && echo OK
# 4. LB に戻す → 次のホストへ
```

- マイグレーションを伴う更新は、**先に 1 台（init ロール）で `ECCUBE_SKIP_DB_INIT=0`
  にして適用**してから残りを更新する（後方互換のあるスキーマ変更にすること）。
- 単一ホスト（compose.yaml）の場合はこの手順は使えず、`up -d --build` の数十秒の
  停止を許容するか、メンテナンス画面を挟む。

### さらに上（Tier 3）

- DB リードレプリカ（Doctrine の read/write 分割）、マネージド DB/Redis（RDS/Aurora・
  ElastiCache）、ECS/EKS/k8s + オートスケール、CloudFront/Cloudflare CDN。規模とコストに
  応じて設計する。

> フルページキャッシュ（nginx `fastcgi_cache`）は既定で無効。EC-CUBE はページに
> CSRF トークン・カート・ログイン状態を埋め込むため、誤配信の危険がある。有効化する
> 場合の雛形と注意は `docker/nginx/default.conf` 末尾のコメントを参照。

## メール送信の非同期化（Messenger）

メールはキュー経由で送信される（Symfony Messenger + Doctrine transport）。

- **注文完了などのレスポンスが SMTP 応答を待たない**（同期送信だと外部 SMTP の
  遅延・障害が購入処理に直結する）。
- SMTP 停止中もメッセージは DB（`messenger_messages`）に残り、復旧後に送信される
  （5s→15s→45s で 3 回リトライ → `failed` キューへ）。
- consumer は `worker` サービス（`messenger:consume async`）。`--time-limit=3600` で
  定期再起動し、restart ポリシーで常駐。healthcheck（プロセス監視）つき。

運用コマンド:

```bash
docker compose logs -f worker                    # 送信ログ
docker compose exec worker runuser -u www-data -- php bin/console messenger:stats
docker compose exec worker runuser -u www-data -- php bin/console messenger:failed:show
docker compose exec worker runuser -u www-data -- php bin/console messenger:failed:retry
```

> 同期送信に戻すには `app/config/eccube/packages/messenger.yaml` を削除して
> `worker` を止めるだけ。Messenger パッケージはイメージビルド時に追加している
> （`docker/php/Dockerfile`。本体ソースは非編集・再ビルドで再現）。

**テスト環境だけは同期送信に戻している**（`app/config/eccube/packages/test/messenger.yaml`）。
`messenger.yaml` には env 指定が無く test にも効いてしまうため、そのままだとテスト中の
メールがキューに積まれるだけで Symfony のテスト用 Transport に届かず、本体が持つ
`assertEmailCount()` 系のテストが軒並み「0 sent」で落ちる。

```yaml
framework:
    messenger:
        transports:
            async: 'sync://'   # ルーティング定義はそのまま、transport だけ同期に
```

## バックアップ / 復元

DB（受注・会員）とアップロード画像を 1 コマンドでバックアップできる。

```bash
bin/backup.sh                        # ./backups/<日時>/ に db.sql.gz + upload.tar.gz
BACKUP_DIR=/mnt/nas bin/backup.sh    # 保存先変更
BACKUP_KEEP=14 bin/backup.sh         # 保持世代数（既定 7）

bin/restore.sh backups/20260721-040000   # 復元（確認プロンプトあり）
```

- DB は `mysqldump --single-transaction`（InnoDB 前提・**無停止で整合ダンプ**）
- cron 例（毎日 4:00）:
  ```
  0 4 * * * cd /path/to/eccube-docker && bin/backup.sh >> var/backup.log 2>&1
  ```
- バックアップ先はサーバー外（NAS / オブジェクトストレージ）へ同期すること。
  サーバー本体と同じディスクに置くだけでは障害時に共倒れになる。

## 監視 / 可観測性

- **コンテナ死活**: `ec-cube`（php-fpm を FastCGI ping）を含む全サービスに healthcheck が
  あり、`docker compose ps` で healthy/unhealthy が分かる。nginx は ec-cube が healthy に
  なってから起動する。
- **db は認証まで確認する**。アプリと同じ経路（TCP + `DB_USER` + `DB_NAME`）で
  `SELECT 1` を流す。`mysqladmin ping` はサーバーが生きていれば**認証に失敗しても
  成功を返す**ので、DB ボリュームに焼かれたパスワードと `.env` が食い違っても healthy に
  なってしまう。`down -v` せずに `.env` の `DB_PASSWORD` を変えると起こり、
  「healthy なのにアプリだけ 500」という切り分けにくい状態になる。
  **パスワードを変えるときは DB 側も変える**:
  ```bash
  docker compose exec -T db sh -s <<'EOF'
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
  ALTER USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
  FLUSH PRIVILEGES;
  SQL
  EOF
  ```
  root のパスワードまで見失った場合は、`--skip-grant-tables` で一時起動して
  `ALTER USER` すれば**データを保ったまま**復旧できる（`down -v` は不要）。
- **php-fpm の飽和**（`max_children` 到達＝リクエスト滞留）は status page で確認:
  ```bash
  docker compose exec ec-cube sh -c \
    'SCRIPT_NAME=/fpm-status SCRIPT_FILENAME=/fpm-status REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000'
  # active processes / idle processes / listen queue / max children reached を見る
  ```
  `max children reached` が増えていたら `PHP_FPM_MAX_CHILDREN` を上げる（メモリと相談）。
- **Docker ログ**は全サービス 10MB×5 世代で上限あり（ディスク食い潰し防止）。
- **外形監視**は UptimeRobot / Cloudflare Health Checks 等で `/` を監視する
  （`bin/healthcheck.sh` はローカル手動確認用）。

## ユニットテスト

自分のコードのテストは **`app/Customize/Tests/`** に置く（`Customize\` 名前空間で
autoload されるので、対象クラスをそのまま `use` できる。本体は汚さない）。

> ルート直下の `tests/` にしない理由: autoload には `composer.json` の追記が要るが、
> それはイメージにベイクされるため **バージョン切替（再ビルド）のたびに消える**。
> `Customize\` は本体 composer.json がどのバージョンでも保証するので、
> `app/Customize/Tests/` なら設定ゼロで切替後も壊れない。

```bash
bin/test.sh                       # 全テスト（app/Customize/Tests/）
bin/test.sh --filter testAddition # 絞り込み
bin/test.sh --testdox             # 読みやすい出力
bin/test.sh app/Plugin/Foo/Tests  # パス指定で任意のテストも実行できる
```

- 設定（プロジェクトルート）の testsuite は `app/Customize/Tests` に限定して
  いるが、**パスを引数で渡せばプラグインのテストもこの設定で走る**。
- EC-CUBE 本体のフルスイート（重い・DB 必須）は image の `phpunit.xml.dist` に残してある。
  必要なときだけ `docker compose exec ec-cube runuser -u www-data -- vendor/bin/phpunit -c phpunit.xml.dist`。

### 設定ファイルはバージョン別に 2 本

EC-CUBE のバージョンで PHPUnit の系列が変わり、設定の書式が相互に非互換になる。

| EC-CUBE | PHPUnit | DAMA | 設定ファイル | DAMA の登録 | カバレッジ対象 |
| --- | --- | --- | --- | --- | --- |
| 4.2 / 4.3 | 9.6 | 6.x | `phpunit.xml` | `<listeners><listener>` | `<coverage>` |
| 4.4〜 | 11 | 8.x | `phpunit.11.xml` | `<extensions><bootstrap>` | `<source>` |

**どちらを使うかは `bin/test.sh` が自動で選ぶ。** `.env` の `ECCUBE_VERSION` ではなく
コンテナの `vendor/bin/phpunit` の実バージョンを見るので、再ビルドや依存解決の結果が
ズレていても正しい方が選ばれる。バージョンを切り替えたあと、テスト側で何かする必要は無い。

書式が合わない設定を渡しても **PHPUnit は警告を出して読み飛ばすだけで止まらない**。
その結果 DAMA のロールバックが黙って無効化され、テストが本番と同じ DB に書き込み続ける
（実際に商品が 12,000 件残ってフロントが落ちた）。静かに壊れるのが最悪なので、
`bin/test.sh` は実行の前後で次を検査し、引っかかったら **テストが緑でも終了コード 1** を返す。

1. コンテナの PHPUnit のメジャーバージョンを取得し、対応する設定ファイルを選ぶ
2. ホストとコンテナで設定ファイルのバイト数が一致するか（bind mount の取り違え検出）
3. コンテナ側の設定を DOM で読み、DAMA の登録方法がそのバージョンと噛み合っているか
4. 実行ログに `The configuration file did not pass validation!` が出ていないか

設定を編集するときは **両方のファイルを同じ内容に保つこと**（片方だけ直すと、
バージョンを切り替えた瞬間に差分が出る）。

### DB を使う統合テストを書くとき

`Eccube\Tests\EccubeTestCase` などを継承する統合テスト（`WebTestCase` 系を含む）は、
既定の設定でそのまま走る。

- **`APP_ENV=test` はコンテナのプロセス環境として渡す必要がある**（`bin/test.sh` が
  やっている）。コンテナは既定で `APP_ENV=prod` を持っており、Symfony の
  `KernelTestCase` は `$_ENV`/`$_SERVER` の `APP_ENV` を先に見るため、`phpunit.xml` の
  `<server>` 指定だけでは prod カーネルが起動し、
  `framework.test config is not set to true` で全部落ちる。
- **DAMA\DoctrineTestBundle をテスト設定に入れてある**。各テストが
  トランザクションで包まれてロールバックされるので、DB にデータが残らない。これが
  無いと実行のたびにレコードが積み上がり、件数を前提にしたテストが後から壊れる
  （実際に会員グループが数千件溜まって既存テストが落ちた）。バンドル自体は本体が
  test 環境向けに登録済み（`app/config/eccube/bundles.php`）。
- **メールはテスト環境だけ同期送信に戻してある**（`app/config/eccube/packages/test/messenger.yaml`）。
  本番の非同期送信設定が test にも効くと、`assertEmailCount()` を使うテストが
  「0 sent」で落ちる。詳細は「メール送信の非同期化」節。
- テスト用 DB は分けておらず、開発用の DB をそのまま使う。上のロールバックがあるので
  データは汚れないが、**本番の DB では絶対に実行しないこと**。

> `phpunit.xml` / `phpunit.11.xml` は単一ファイルとして bind-mount している。ホスト側で
> 編集すると inode が変わってコンテナ側が古い内容を見続けるので、
> `docker compose up -d --force-recreate ec-cube` でマウントを張り直す
> （`bin/test.sh` がバイト数の食い違いで検出して止める）。

## framework 級設定（monolog 等）の置き場所について

EC-CUBE 4.3 の `src/Eccube/Kernel.php::configureContainer()` は、
`app/config/eccube/packages/*.yaml` と `app/Customize/Resource/config/services.yaml` を
**同じ `$loader`・同じコンテナビルド（extension 処理）フェーズ**で読み込む。よって
`monolog:` 等の framework 級キーは **どちらのファイルに書いても拾われる**。

本テンプレートでは、DI 設定（services.yaml）と framework 級設定を分離する方針で
`app/config/eccube/packages/logging.yaml` に置いているだけで、技術的な制約ではない。

> この点は本環境で実証済み。`packages/` から `monolog:` を外し、
> `app/Customize/Resource/config/services.yaml` にだけ書いた状態で
> `bin/console debug:container monolog.logger.<channel>` がサービスを解決した。

## 注意

- **`app/Customize/` と `app/template/` は空にできない**。EC-CUBE 本体の設定が
  `app/Customize/{Controller,Entity,Resource/locale}` や `app/template/{default,admin,…}`
  の存在を前提にしており、bind-mount で空ディレクトリを重ねると本体既定を隠して起動に
  失敗する。そのため本リポジトリは EC-CUBE 既定と同じ空スケルトン（`.gitkeep`）を同梱している。
- bind-mount した `app/*` はホストの uid で所有される。Linux で `make:migration` 等が
  権限エラーになる場合は、当該ディレクトリを www-data(uid 33) が書けるようにする。
