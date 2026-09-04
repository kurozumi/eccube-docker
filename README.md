# EC-CUBE 4 を開発から本番まで同じ構成で動かす Docker 環境

各社 VPS でも AWS でも**同じ手順**でインストールから公開までできる。
`git clone && bin/init.sh` で開発環境が立ち上がり、そのまま `bin/publish.sh` で公開できる。

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
│   └── assets/{css/{customize.css, customize-theme.css}, js/customize.js}
├── html/template/original/ # オリジナルテーマの静的物（bin/theme.sh init が本体から写す）
├── docker/
│   ├── php/{Dockerfile,php.ini,www-pool.conf.tmpl,docker-entrypoint.sh}
│   ├── nginx/{default.conf,lb.conf.example}
│   ├── mariadb/conf.d/eccube.cnf
│   └── caddy/Caddyfile
└── bin/{init,upgrade,switch-version,reset,publish,healthcheck,assets,plugin,test,ide-sync,backup,restore}.sh
```

## 必要環境

- Docker Engine / Docker Compose v2.24 以上（`compose.prod.yaml` で `!override` を使用）
- amd64 / arm64 どちらも可

## クイックスタート（開発）

**この環境を配布物として受け取って使う側は [導入手順](docs/install.md) を見ること。**
そちらは `git clone` せず、リリースから**自分のリポジトリ**として始める手順になっている
（clone だと origin が配布元のままで、自分のコードを自分の GitHub で管理できない）。

以下はこのリポジトリ自体を開発する場合。

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

### よく使うコマンド

```bash
bin/console.sh <cmd>       # コンテナの中で bin/console を実行（www-data 固定）
bin/shell.sh               # コンテナの中に入る（www-data 固定。--root で root）
bin/plugin.sh reload       # PHP / 設定を触ったあとのキャッシュ一掃
bin/plugin.sh doctor       # システムエラーが出たときの点検と修復
bin/test.sh <パス>          # テスト（素の phpunit は使わない）
bin/backup.sh              # DB と画像のバックアップ
```

**`bin/console.sh` と `bin/shell.sh` は www-data で実行する。** root で走らせると
`var/cache` と `var/log` に root 所有のファイルができ、php-fpm が書けなくなって
**全ページ 500** になる。手で打つと付け忘れるのでラッパーに固定してある。
root が要るのはパッケージの導入など限られた場面だけで、そのときは `--root`。

## ドキュメント

用途ごとに `docs/` へ分けてある。**README はここまでで、以降は各文書を見ること。**

| 文書 | 中身 |
| --- | --- |
| [導入手順](docs/install.md) | **使う人向けの入口。** 取得から公開まで、そのあとの更新の受け取り方 |
| [カスタマイズ](docs/customize.md) | 本体を汚さずに実装を足す場所。Controller / Entity / テンプレート / 独自 CSS・JS / framework 級設定 / コンテナに入る / migration |
| [バージョン切替 / バージョンアップ](docs/upgrade.md) | 運用中の店舗を上げる手順、切り戻し、プラグインの互換性 |
| [本番デプロイ](docs/deploy.md) | どのサーバーでも同じ手順で公開する |
| [配布と更新](docs/distribute.md) | この環境を人に渡し、更新を届ける。**環境の更新と本体の更新は別物** |
| [バックアップ / 復元](docs/backup.md) | DB と画像の保全。**バージョンアップの前に必ず取る** |
| [データを失わないために](docs/data-safety.md) | **`down` と `down -v` の違い**、消えるコマンド、消したときの復旧 |
| [大規模アクセス / スケール](docs/scale.md) | 1台で捌く → 状態を外へ出す → 複数ホスト。セッション共有・画像共有・LB・メールの非同期化 |
| [監視 / 可観測性](docs/monitoring.md) | ログの見方と死活監視 |
| [ユニットテスト](docs/testing.md) | `bin/test.sh` の使い方と、素の phpunit を使ってはいけない理由 |
| [IDE の設定](docs/ide.md) | PhpStorm でコード補完を効かせる |

## 注意

- **`app/Customize/` と `app/template/` は空にできない**。EC-CUBE 本体の設定が
  `app/Customize/{Controller,Entity,Resource/locale}` や `app/template/{default,admin,…}`
  の存在を前提にしており、bind-mount で空ディレクトリを重ねると本体既定を隠して起動に
  失敗する。そのため本リポジトリは EC-CUBE 既定と同じ空スケルトン（`.gitkeep`）を同梱している。
- bind-mount した `app/*` はホストの uid で所有される。Linux で `make:migration` 等が
  権限エラーになる場合は、当該ディレクトリを www-data(uid 33) が書けるようにする。
