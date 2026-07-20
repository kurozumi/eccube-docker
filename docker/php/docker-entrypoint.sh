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

# 0) php-fpm プールを env から生成（envsubst）。テンプレ/コマンドが無ければ黙って飛ばす。
POOL_TMPL=/usr/local/etc/php/eccube/www-pool.conf.tmpl
POOL_OUT=/usr/local/etc/php-fpm.d/zzz-eccube-pool.conf
if command -v envsubst >/dev/null 2>&1 && [ -f "$POOL_TMPL" ]; then
    : "${PHP_FPM_PM:=dynamic}"
    : "${PHP_FPM_MAX_CHILDREN:=20}"
    : "${PHP_FPM_START_SERVERS:=4}"
    : "${PHP_FPM_MIN_SPARE:=2}"
    : "${PHP_FPM_MAX_SPARE:=6}"
    : "${PHP_FPM_MAX_REQUESTS:=500}"
    export PHP_FPM_PM PHP_FPM_MAX_CHILDREN PHP_FPM_START_SERVERS \
           PHP_FPM_MIN_SPARE PHP_FPM_MAX_SPARE PHP_FPM_MAX_REQUESTS
    envsubst '${PHP_FPM_PM} ${PHP_FPM_MAX_CHILDREN} ${PHP_FPM_START_SERVERS} ${PHP_FPM_MIN_SPARE} ${PHP_FPM_MAX_SPARE} ${PHP_FPM_MAX_REQUESTS}' \
        < "$POOL_TMPL" > "$POOL_OUT"
    log "php-fpm プール: pm=$PHP_FPM_PM max_children=$PHP_FPM_MAX_CHILDREN"
fi

# 0b) 環境別 OPcache。prod は timestamp 検証を切って stat を無くす（要リビルドで反映）。
#     zzzz- は zzz-eccube.ini より後に読まれ、同名ディレクティブを上書きする。
RUNTIME_INI=/usr/local/etc/php/conf.d/zzzz-eccube-runtime.ini
if [ "$APP_ENV" = "prod" ]; then
    {
        echo "opcache.validate_timestamps=0"
        echo "opcache.interned_strings_buffer=32"
        echo "opcache.memory_consumption=256"
        echo "opcache.max_wasted_percentage=10"
        echo "realpath_cache_size=4096K"
        echo "realpath_cache_ttl=600"
    } > "$RUNTIME_INI"
    log "OPcache: prod（validate_timestamps=0）"
else
    {
        echo "opcache.validate_timestamps=1"
        echo "opcache.revalidate_freq=0"
    } > "$RUNTIME_INI"
    log "OPcache: dev（validate_timestamps=1）"
fi

# 1) ホストの app/config/eccube/packages/* を本体へマージ（追加・上書きのみ。既定は消さない）
if [ -d /opt/eccube-config/packages ] && [ -n "$(ls -A /opt/eccube-config/packages 2>/dev/null)" ]; then
    log "app/config/eccube/packages へホスト設定をマージ"
    cp -a /opt/eccube-config/packages/. app/config/eccube/packages/
    chown -R www-data:www-data app/config/eccube/packages || true
fi

# var/ は www-data が書けるように
chown -R www-data:www-data var 2>/dev/null || true

# アップロード画像は専用ボリューム（初回や NFS 差し替え時は空）。必要な
# サブディレクトリを用意して www-data 所有にする（無いとアップロードが失敗する）。
for d in save_image temp_image; do
    mkdir -p "html/upload/$d"
done
chown -R www-data:www-data html/upload 2>/dev/null || true

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

# 3) DB スキーマ操作。
#    複数ホスト構成では「init ロール 1 台だけ」が install/migrate を行い、
#    「app ロール（ECCUBE_SKIP_DB_INIT=1）」はスキーマに触らず cache:clear だけ行う
#    （全 app ホストが一斉に migrate すると競合するため）。単一ホストなら未設定でよい。
MARKER="$APP_DIR/var/.eccube_installed"
# ECCUBE_SKIP_CACHE_CLEAR=1: cache:clear もスキップする。
# 同一ホストで --scale する際、レプリカは同じ eccube_app ボリューム（var/cache）を
# 共有するため、追加レプリカの cache:clear が稼働中レプリカのコンパイル済み
# コンテナを一瞬消して 500 を出し得る。追加レプリカはこのフラグで何も触らせない。
if [ "${ECCUBE_SKIP_DB_INIT:-0}" = "1" ]; then
    if [ "${ECCUBE_SKIP_CACHE_CLEAR:-0}" = "1" ]; then
        log "scale レプリカ: DB 初期化・cache:clear ともスキップ"
    else
        log "app ロール: DB 初期化/マイグレーションをスキップ（cache:clear のみ）"
        runuser -u www-data -- php bin/console cache:clear --no-interaction || true
    fi
elif [ ! -f "$MARKER" ]; then
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
    # bind-mount した app/config・app/Customize の変更を prod のコンパイル済み
    # コンテナへ反映するため、毎起動でキャッシュを作り直す（dev では無害）。
    runuser -u www-data -- php bin/console cache:clear --no-interaction || true
fi

exec "$@"
