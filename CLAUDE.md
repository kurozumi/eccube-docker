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
- **性能/スケール（Tier 1）**: php-fpm は `.env` の `PHP_FPM_*`、OPcache は entrypoint が
  `APP_ENV` で切替、Redis 共有キャッシュは `app/config/eccube/packages/cache.yaml`、DB は
  `docker/mariadb/conf.d/`、nginx は gzip/静的キャッシュ済み。詳細は README「大規模アクセス」。
- **セッション Redis 共有（Tier 2）**: 専用 `redis-session` に保存し複数ホストで共有。
  本体の SameSite ハンドラは維持し内側だけ `Customize\Session\RawRedisSessionHandler` に
  差し替え（`app/Customize/Resource/config/services.yaml`、`SESSION_REDIS_URL`）。
- **アップロード画像（Tier 2）**: `html/upload` は専用ボリューム `eccube_upload` に分離。
  複数ホストは NFS/EFS ドライバに差し替えて共有。`down -v`（reset/switch-version）で
  ローカルデータは消えるので事前バックアップ。詳細は README「アップロード画像の共有ストレージ」。

## よく使う操作

```bash
bin/init.sh                    # 初回セットアップ
bin/switch-version.sh ~4.2.0   # バージョン切替（データ破棄）
bin/reset.sh                   # DB 初期化
bin/publish.sh                 # 本番構成で起動
docker compose exec ec-cube runuser -u www-data -- php bin/console <cmd>

bin/assets.sh build            # 独自 scss → html/user_data/assets/css/customize.css
bin/assets.sh watch            # 上記を監視ビルド（dev の node サービス）
bin/assets.sh core-build       # 本体テーマ丸ごとの純正ビルド（Gulp/Webpack・Git 管理外）

# プラグイン例（dev で app/Plugin が rw のとき）
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:generate <Name>
```

## 開発フロー（重要）

- **`main` へ直接コミット・直接プッシュしない。** 変更は必ず作業ブランチを切り、
  プルリクエストを作成する。
- **マージはオーナー（kurozumi）が行う。** 明示的に「マージして」と指示されない限り、
  自分で `gh pr merge` しない。
- リポジトリ初期化時の初回プッシュのみ、例外的に直接 `main` へ反映済み。
