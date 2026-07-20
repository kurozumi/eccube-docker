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
  | `app/DoctrineMigrations/` | `app/DoctrineMigrations` | 独自マイグレーション（開発は rw） |
  | `app/config/eccube/packages/` | 同左（entrypoint がマージ） | monolog 等の framework 級設定 |

- **本体のマイグレーションは同期不要**（イメージにベイク済み。`eccube:install` /
  `doctrine:migrations:migrate` が適用する）。同期が要るのは *自分で書く*
  `app/DoctrineMigrations/` だけ。

## ディレクトリ

```
.
├── compose.yaml            # base（ec-cube / nginx / db / mailpit）
├── compose.override.yaml   # 開発用（自動読込: phpMyAdmin・Mailpit UI・rw マウント）
├── compose.prod.yaml       # 本番用（-f で指定。公開層をプロファイルで選択）
├── .env.example
├── app/                    # ← Git 管理する「自分のコード」
│   ├── Customize/Resource/config/services.yaml
│   ├── template/
│   ├── DoctrineMigrations/
│   ├── Plugin/             # プラグイン（開発・ストア導入）
│   └── config/eccube/packages/logging.yaml
├── frontend/               # 独自テーマの Sass ソース
│   ├── package.json        # Dart Sass ビルド定義
│   └── scss/customize.scss
├── html/user_data/         # 独自 CSS/JS（本体が自動読込）
│   └── assets/{css/customize.css, js/customize.js}
├── docker/
│   ├── php/{Dockerfile,php.ini,docker-entrypoint.sh}
│   ├── nginx/default.conf
│   └── caddy/Caddyfile
└── bin/{init,switch-version,reset,publish,healthcheck,assets}.sh
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
- **プラグイン** は `app/Plugin/`。dev では rw マウントなので生成・導入できる:
  ```bash
  docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:generate MyPlugin
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

## バージョン切替

```bash
bin/switch-version.sh ~4.2.0   # .env 書換 → down -v → build → up → 再install
```

スキーマが変わるため、切替はデータを破棄して作り直す。複数バージョンを並行運用したい
場合は、別ディレクトリに clone するか `.env` の `COMPOSE_PROJECT_NAME` を分ける。

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

## 大規模アクセス / スケール（Tier 1）

単一ホストのまま高トラフィックに耐えるための強化が入っている（本体は非編集）。

| 強化 | 場所 | 調整 |
|---|---|---|
| php-fpm ワーカー数 | entrypoint が env から生成 | `.env` の `PHP_FPM_*` |
| 本番 OPcache（`validate_timestamps=0`） | entrypoint（`APP_ENV=prod` で自動） | — |
| Redis 共有キャッシュ（Symfony app cache） | `redis` サービス＋`app/config/eccube/packages/cache.yaml` | `REDIS_URL` |
| MariaDB バッファプール等 | `docker/mariadb/conf.d/eccube.cnf` | `innodb_buffer_pool_size` を RAM に合わせる |
| gzip / 静的長期キャッシュ | `docker/nginx/default.conf` | — |

**まず調整すべき2点**: `PHP_FPM_MAX_CHILDREN`（＝同時処理数。メモリから算出）と
`innodb_buffer_pool_size`（＝専用 DB なら RAM の 50〜70%）。

### 水平スケール（1台の中で php-fpm を増やす）

```bash
docker compose up -d --scale ec-cube=3
```

nginx は Docker 内蔵 DNS を毎回引き直して各レプリカへ分散する（内部ロードバランス）。
実測で 2 レプリカに約 11:9 で振り分き、1 台停止時も残りが 200 を返し継続（フェイルオーバー）。

注意点:
- 各レプリカは起動時に `migrate` と `cache:clear` を実行する。未適用マイグレーションが
  ある状態で一斉起動すると競合しうるので、**先に 1 台で適用してからスケール**する。
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
  勝手に消えないようにしている。
- 単一ホストのみで運用するなら不要。この 3 定義（services.yaml）と `redis-session`
  サービスを外せばファイルセッションに戻る。

> 実測: ログイン系ページで発行される `eccube` セッション ID が `redis-session` に
> `ecses:<id>`（TTL≈`gc_maxlifetime`）として保存され、`--scale=2` でも両レプリカから
> 同一セッションを参照できることを確認済み。`var/sessions` には新規作成されない。

### さらに上（Tier 2 の残り / Tier 3）

- 複数ホストへ広げるなら、前段に外部 LB（ALB / Cloudflare LB 等）、DB リードレプリカ、
  画像の S3+CDN、マネージド Redis/DB（ElastiCache 等）。ECS/EKS/k8s + オートスケールは
  コスト・運用が増えるため、必要規模に応じて別途設計する。

> フルページキャッシュ（nginx `fastcgi_cache`）は既定で無効。EC-CUBE はページに
> CSRF トークン・カート・ログイン状態を埋め込むため、誤配信の危険がある。有効化する
> 場合の雛形と注意は `docker/nginx/default.conf` 末尾のコメントを参照。

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
```

- 対象は `phpunit.xml`（プロジェクトルート）で `app/Customize/Tests` に限定している。
  純粋なユニットテスト（`PHPUnit\Framework\TestCase` 継承）は **DB 不要**で走る。
- EC-CUBE 本体のフルスイート（重い・DB 必須）は image の `phpunit.xml.dist` に残してある。
  必要なときだけ `docker compose exec ec-cube runuser -u www-data -- vendor/bin/phpunit -c phpunit.xml.dist`。

### DB を使う統合テストを書くとき

`Eccube\Tests\EccubeTestCase` などを継承する統合テストは、テスト用 DB とスキーマが要る。

```bash
# テスト用 DB を作成してスキーマを構築（例）
docker compose exec ec-cube runuser -u www-data -- \
  php bin/console doctrine:database:create --env=test --if-not-exists
docker compose exec ec-cube runuser -u www-data -- \
  php bin/console doctrine:schema:create --env=test
```

さらに `phpunit.xml` に DAMA\DoctrineTestBundle リスナー（各テストをトランザクションで
包んでロールバックする）を足すと、テストがデータを汚さない。設定例は本体の
`phpunit.xml.dist` を参照。

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
