# CLAUDE.md

EC-CUBE 4 の汎用 Docker 環境。本体はイメージにベイクし、`app/` 配下（Customize /
template / DoctrineMigrations / config）だけを bind-mount して Git 管理する。

## 原則

- **EC-CUBE 本体を直接編集しない**。カスタマイズは `app/Customize/`、テンプレート上書きは
  `app/template/`、スキーマ変更は `app/DoctrineMigrations/` に置く。
- **バージョンは `.env` の `ECCUBE_VERSION`**（build-arg）。切替は `bin/switch-version.sh`。
- **framework 級設定（monolog 等）は `app/config/eccube/packages/`**。entrypoint が起動時に
  本体の `app/config/eccube/packages/` へマージする（既定は消さない）。
- 既定は本番モード。開発でデバッグするときだけ `.env` を `APP_ENV=dev` にする。

## よく使う操作

```bash
bin/init.sh                    # 初回セットアップ
bin/switch-version.sh ~4.2.0   # バージョン切替（データ破棄）
bin/reset.sh                   # DB 初期化
bin/publish.sh                 # 本番構成で起動
docker compose exec ec-cube runuser -u www-data -- php bin/console <cmd>
```

## 開発フロー（重要）

- **`main` へ直接コミット・直接プッシュしない。** 変更は必ず作業ブランチを切り、
  プルリクエストを作成する。
- **マージはオーナー（kurozumi）が行う。** 明示的に「マージして」と指示されない限り、
  自分で `gh pr merge` しない。
- リポジトリ初期化時の初回プッシュのみ、例外的に直接 `main` へ反映済み。
