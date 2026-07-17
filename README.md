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
│   └── config/eccube/packages/logging.yaml
├── docker/
│   ├── php/{Dockerfile,php.ini,docker-entrypoint.sh}
│   ├── nginx/default.conf
│   └── caddy/Caddyfile
└── bin/{init,switch-version,reset,publish,healthcheck}.sh
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
