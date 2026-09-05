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

# 0a) www-data の uid / gid をホストのユーザーに合わせる（PUID / PGID）。
#
# bind mount した app/template や html/user_data に、管理画面（PHP = www-data）が
# 書く。Linux では www-data（uid 33）が書いたファイルはホストの deploy ユーザーから
# 見て他人のもので、**次の git pull が書けずに落ちる**。逆にホストが置いたファイルは
# www-data が書けず、**管理画面の保存が失敗する**（本体は is_writable が偽だと
# 欄を空で出すので、症状は「空に見える」）。
# uid を揃えれば、どちらの向きの食い違いも根本から消える。macOS の Docker Desktop
# は所有者が透過なので未設定でよい。
if [ -n "${PUID:-}" ] && [ "$PUID" != "$(id -u www-data)" ]; then
    log "www-data の uid を ${PUID} に合わせます（PUID）"
    usermod -o -u "$PUID" www-data
    # 名前付きボリュームの中（vendor / var / app/proxy）は古い uid のまま。
    # 揃えないと php-fpm が自分のキャッシュに書けない。bind mount は別マウントなので
    # -xdev で除外する（ホストのファイルの所有者は触らない）。
    log "ボリューム内の所有者を揃えます（初回だけ。1 分ほど）..."
    find "$APP_DIR" -xdev \( -user 33 -o -group 33 \) -exec chown -h www-data:www-data {} + 2>/dev/null || true
fi
if [ -n "${PGID:-}" ] && [ "$PGID" != "$(id -g www-data)" ]; then
    log "www-data の gid を ${PGID} に合わせます（PGID）"
    groupmod -o -g "$PGID" www-data
fi

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

# 1a) 任意機能の設定を、COMPOSE_PROFILES（ECCUBE_PROFILES として渡る）で選ぶ。
#     入れるだけでなく**外すときは消す**。マージは足すだけなので、消さないと
#     前回の設定が残り、Redis を止めたのに接続しに行って全ページ 500 になる。
#     旧名（cache.yaml / messenger.yaml）はこの環境が以前マージしたもので、
#     本体には無い（4.4 の素のイメージで確認済み）。中身の目印を見てから消す。
profiles=",${ECCUBE_PROFILES:-},"
optional_set() { # optional_set <名前> <旧ファイル名…>
    local name="$1"; shift
    local src="/opt/eccube-config/optional/${name}"
    if [ "${profiles#*,${name},}" != "$profiles" ]; then
        if [ -d "$src" ]; then
            log "任意機能 ${name}: 有効（設定をマージ）"
            cp -a "$src"/*.yaml app/config/eccube/packages/ 2>/dev/null || true
        else
            log "任意機能 ${name}: プロファイルは有効だが設定ディレクトリが無い（${src}）"
        fi
    else
        for f in "$src"/*.yaml; do
            [ -f "$f" ] && rm -f "app/config/eccube/packages/$(basename "$f")"
        done
        for legacy in "$@"; do
            local lf="app/config/eccube/packages/${legacy}"
            if [ -f "$lf" ] && grep -q "この環境\|Redis に載せる\|非同期化" "$lf" 2>/dev/null; then
                log "任意機能 ${name}: 無効。旧設定 ${legacy} を外します"
                rm -f "$lf"
            fi
        done
    fi
}
optional_set redis cache.yaml
optional_set messenger messenger.yaml
chown -R www-data:www-data app/config/eccube/packages || true

# var/ は www-data が書けるように
chown -R www-data:www-data var 2>/dev/null || true

# 1b) Messenger（メール非同期化）が volume 内 vendor に無ければ一度だけ追加する。
#     イメージには焼き込み済みだが、既存の eccube_app volume はイメージ内容を
#     覆い隠すため、旧 volume 環境では初回にここで追加される（要ネットワーク）。
if [ ! -d vendor/symfony/messenger ]; then
    log "symfony/messenger を追加インストール（既存 volume への初回のみ）"
    # --no-plugins: Flex レシピを止める。レシピは phpunit.xml（:ro mount）等を
    # 書き換えようとして失敗する。設定は自前の messenger.yaml を使うので不要。
    # バージョンは固定せず composer に解決させる（Dockerfile 側と同じ理由。
    # 4.2 系 = Symfony 5.4 / 4.3 系 = Symfony 6.4 で必要な messenger の系列が違う）。
    runuser -u www-data -- composer require --no-interaction --no-scripts --no-plugins \
        "symfony/messenger:*" "symfony/doctrine-messenger:*" \
        || log "警告: messenger の追加に失敗しました"
fi
# フェイルセーフ: それでも messenger が無ければ、マージ済みの messenger.yaml を
# 取り除く（設定だけ残るとコンテナのコンパイルが失敗し全ページ 500 になるため）。
# この場合メールは従来どおり同期送信で動く。
if [ ! -d vendor/symfony/messenger ] && [ -f app/config/eccube/packages/messenger_async.yaml ]; then
    log "messenger 不在のため messenger_async.yaml を外します（同期送信で継続）"
    rm -f app/config/eccube/packages/messenger_async.yaml
fi

# アップロード画像は専用ボリューム（初回や NFS 差し替え時は空）。必要な
# サブディレクトリを用意して www-data 所有にする（無いとアップロードが失敗する）。
for d in save_image temp_image; do
    mkdir -p "html/upload/$d"
done
chown -R www-data:www-data html/upload 2>/dev/null || true

# 管理画面（CSS 管理 / JS 管理）が直接書く 2 つのディレクトリ。bind mount で
# 本番だけ rw に入れ子にしてある（compose.yaml）。ホスト側の所有者が deploy
# ユーザーだと Linux では www-data が書けず、**エラーではなく「画面が空に見える」**
# （本体は is_writable が偽だとテキストエリアに中身を入れない）。ここで直す。
# macOS の Docker Desktop では所有者が透過なので何も起きない。
for d in html/user_data/assets/css html/user_data/assets/js; do
    [ -d "$d" ] && chown -R www-data:www-data "$d" 2>/dev/null || true
done

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
