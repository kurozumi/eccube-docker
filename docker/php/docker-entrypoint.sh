#!/bin/sh
# EC-CUBE コンテナのエントリポイント。
#  1) ホストから渡された app/config を本体へマージ（本体既定を消さない）
#  2) DB 起動を待つ
#  3) 初回のみ eccube:install、以降は未適用 migration だけ適用
set -e

: "${APP_ENV:=prod}"
: "${APP_DEBUG:=0}"

APP_DIR=/var/www/html
log() { echo "[entrypoint] $*"; }
cd "$APP_DIR"

# 1) ホストの app/config/eccube/packages/* を本体へマージ（追加・上書きのみ。既定は消さない）
if [ -d /opt/eccube-config/packages ] && [ -n "$(ls -A /opt/eccube-config/packages 2>/dev/null)" ]; then
    log "app/config/eccube/packages へホスト設定をマージ"
    cp -a /opt/eccube-config/packages/. app/config/eccube/packages/
    chown -R www-data:www-data app/config/eccube/packages || true
fi

# var/ は www-data が書けるように
chown -R www-data:www-data var 2>/dev/null || true

# 2) DB 待ち（compose の healthcheck の保険）
log "DB 起動待ち..."
i=0
until php -r 'exit(@mysqli_connect(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASSWORD"), getenv("DB_NAME")) ? 0 : 1);' 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        log "警告: DB に接続できませんでした。処理を続行します。"
        break
    fi
    sleep 2
done

# 3) 初回のみインストール。以降は未適用 migration のみ適用。
MARKER="$APP_DIR/var/.eccube_installed"
if [ ! -f "$MARKER" ]; then
    log "eccube:install（初回セットアップ）"
    if runuser -u www-data -- php bin/console eccube:install --no-interaction; then
        runuser -u www-data -- php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration || true
        runuser -u www-data -- php bin/console cache:clear --no-interaction || true
        touch "$MARKER"
        log "セットアップ完了"
    else
        log "eccube:install が失敗しました。ログを確認してください。"
    fi
else
    log "インストール済み。未適用の migration を適用します。"
    runuser -u www-data -- php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration || true
fi

exec "$@"
