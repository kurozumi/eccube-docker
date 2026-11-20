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
# 1c) 追加ライブラリ（app/Customize/composer.extra.json）。
#     **composer.json と vendor は eccube_app volume の中にあり、git にも backup にも入らない。**
#     bin/upgrade.sh はこの volume を作り直すので、コンテナの中で `composer require` した
#     ライブラリは黙って消える（それを使っている app/Customize のコードが「Class not found」で
#     落ちるまで気づけない）。宣言を git 管理のファイルに置き、無ければここで入れ直す。
#
#     形は composer.json と同じ:
#       { "require": { "league/csv": "^9.8" } }
extra_json="$APP_DIR/app/Customize/composer.extra.json"
if [ -f "$extra_json" ]; then
    missing="$(php -r '
        $f = $argv[1];
        $j = json_decode(@file_get_contents($f), true);
        if (!is_array($j) || empty($j["require"]) || !is_array($j["require"])) { exit(0); }
        $out = [];
        foreach ($j["require"] as $name => $ver) {
            if (!preg_match("#^[a-z0-9]([_.-]?[a-z0-9]+)*/[a-z0-9](([_.]|-{1,2})?[a-z0-9]+)*$#", (string) $name)) { continue; }
            if (!is_dir("/var/www/html/vendor/" . $name)) { $out[] = $name . ":" . $ver; }
        }
        echo implode(" ", $out);
    ' "$extra_json" 2>/dev/null || true)"
    if [ -n "$missing" ]; then
        log "追加ライブラリを入れます（app/Customize/composer.extra.json）: ${missing}"
        # shellcheck disable=SC2086  # 複数パッケージを個別の引数として渡す
        runuser -u www-data -- composer require --no-interaction --no-scripts --no-plugins $missing \
            || log "警告: 追加ライブラリの導入に失敗しました。app/Customize/composer.extra.json の指定を確認してください"
    fi
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
# DB_ENGINE（mysql / postgresql）で待ち方を変える。どちらも「認証まで通る」ことを見る
db_ready() {
    case "${DB_ENGINE:-mysql}" in
        postgresql)
            PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" -c 'SELECT 1' >/dev/null 2>&1 ;;
        *)
            php -r 'exit(@mysqli_connect(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASSWORD"), getenv("DB_NAME"), (int) (getenv("DB_PORT") ?: 3306)) ? 0 : 1);' 2>/dev/null ;;
    esac
}
# DB にもう店があるか（EC-CUBE の表 dtb_base_info があるか）。0 = ある、1 = 無い、2 = 分からない（繋がらない）。
# **eccube:install は最初に doctrine:schema:drop --force を打ち、全部の表を消してから作り直す。**
# 印（var/.eccube_installed）はボリュームの中にしか無いので、ボリュームが新しいだけで DB には店がある
# ことがある（複数ホストで新しいホストを init ロールにした、アプリのボリュームだけ作り直した、など）。
# そのまま install すると、受注も会員も消える。だから install の前にここを見る。
db_has_shop() {
    local out
    case "${DB_ENGINE:-mysql}" in
        postgresql)
            out="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT to_regclass('dtb_base_info') IS NOT NULL" 2>/dev/null)" || return 2 ;;
        *)
            out="$(php -r '$c = @mysqli_connect(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASSWORD"), getenv("DB_NAME"), (int) (getenv("DB_PORT") ?: 3306)); if (!$c) { exit(2); } $r = mysqli_query($c, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '"'"'dtb_base_info'"'"'"); if (!$r) { exit(2); } echo mysqli_fetch_row($r)[0] > 0 ? "t" : "f";' 2>/dev/null)" || return 2 ;;
    esac
    case "$out" in t) return 0 ;; f) return 1 ;; *) return 2 ;; esac
}
# DB の指紋。**店の表（dtb_base_info）そのものが作られた印**で、表を作り直すたびに必ず変わる
# （MariaDB / MySQL は information_schema の CREATE_TIME、PostgreSQL は表の oid）。
# **店の基本情報の create_date は使わない。** 初期データの CSV に書かれた固定の値で、何度 install しても
# 同じになり、別のホストが作り直した店を見分けられなかった（検証で、その店を消した）。読めなければ "unknown"
db_shop_stamp() {
    local out
    case "${DB_ENGINE:-mysql}" in
        postgresql)
            out="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT COALESCE(to_regclass('dtb_base_info')::oid::text, '')" 2>/dev/null)" || { echo unknown; return; } ;;
        *)
            out="$(php -r '$c = @mysqli_connect(getenv("DB_HOST"), getenv("DB_USER"), getenv("DB_PASSWORD"), getenv("DB_NAME"), (int) (getenv("DB_PORT") ?: 3306)); if (!$c) { exit(2); } $r = @mysqli_query($c, "SELECT CREATE_TIME FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '"'"'dtb_base_info'"'"'"); if (!$r) { exit(2); } $row = mysqli_fetch_row($r); echo $row ? (string) $row[0] : "";' 2>/dev/null)" || { echo unknown; return; } ;;
    esac
    printf 'stamp:%s' "$out"
}
until db_ready; do
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
# 起動時の migration（インストール済みのとき）。
# **未適用が無ければ何もしない。** あれば、流す前に DB を var/migrate-backup/ へ取る（取れなければ流さない）。
# **失敗を握らない。** 以前は `|| true` で、途中まで当たった DB のままお店を開けていた。失敗したら
# メンテナンス表示（entrypoint:）にして止める。ふだんの反映は bin/deploy.sh（先に退避してから流す）で、
# ここを通るのは「git pull して docker compose up」のように deploy を通らなかったときだけ。
# 表示は bin/deploy.sh が成功したときに外す（bin/plugin.sh doctor は外さない。壊れた DB を公開しないため）。
migrate_backup_dir="$APP_DIR/var/migrate-backup"
entry_maint_on() {
    if [ ! -f "$APP_DIR/.maintenance" ]; then
        printf 'entrypoint:%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$APP_DIR/.maintenance"
        chown www-data:www-data "$APP_DIR/.maintenance" 2>/dev/null || true
    fi
    log "メンテナンス表示にしました（お客さんには「メンテナンス中」。ログイン中の管理者は見えます）。"
}
dump_before_migrate() { # 標準出力へ gzip 前のダンプ
    case "${DB_ENGINE:-mysql}" in
        postgresql)
            PGPASSWORD="$DB_PASSWORD" pg_dump --clean --if-exists -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" "$DB_NAME" ;;
        *)
            MYSQL_PWD="$DB_PASSWORD" mysqldump --single-transaction --triggers --no-tablespaces \
                -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" "$DB_NAME" ;;
    esac
}
migrate_installed() {
    if runuser -u www-data -- php bin/console doctrine:migrations:up-to-date --no-interaction >/dev/null 2>&1; then
        log "インストール済み。未適用の migration はありません。"
        return 0
    fi
    log "インストール済み。未適用の migration があります（または確かめられませんでした）。流す前に DB を取ります..."
    mkdir -p "$migrate_backup_dir"; chmod 700 "$migrate_backup_dir"
    local out
    out="$migrate_backup_dir/$(date +%Y%m%d-%H%M%S).sql.gz"
    # このファイルは /bin/sh（dash）で動くので pipefail が無い。ダンプの終了コードはファイルで受け取る
    local rcf="$migrate_backup_dir/.dump-rc"
    { dump_before_migrate; echo $? > "$rcf"; } | gzip > "$out"
    if [ "$(cat "$rcf" 2>/dev/null)" != 0 ] ||
       ! gunzip -c "$out" | tail -c 1024 | grep -qE -- '-- (PostgreSQL database dump complete|Dump completed)'; then
        rm -f "$rcf"
        rm -f "$out"
        log "エラー: DB を取れなかったので、migration は流しません（取れないまま流すと、失敗したときに戻せない）。"
        entry_maint_on
        log "DB に繋がるか確かめてから、bin/deploy.sh で反映してください（先に退避してから流します）。"
        return 0
    fi
    rm -f "$rcf"
    chmod 600 "$out"
    # 新しい 3 つだけ残す（ボリュームの中なので、溜めない。長く持つのは bin/backup.sh の役目）
    ls -1 "$migrate_backup_dir"/*.sql.gz 2>/dev/null | sort | head -n -3 2>/dev/null | xargs -r rm -f 2>/dev/null || true
    log "取りました: ${out#"$APP_DIR"/}（コンテナの中。戻すなら docker compose cp で取り出して流し込む）"
    if runuser -u www-data -- php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration; then
        return 0
    fi
    log "エラー: migration が失敗しました。途中まで当たった DB でお店を開けないよう、止めます。"
    entry_maint_on
    log "流す前の DB: ${out#"$APP_DIR"/}。原因を直して bin/deploy.sh で反映し直すか、bin/restore.sh で戻してください。"
    return 0
}
# このボリュームで始めた eccube:install が途中で失敗した印。中身は**失敗した時点の DB の指紋**
# （db_shop_stamp。店の基本情報の作成日時）。次の起動で DB の指紋が**同じときだけ**やり直す
# （このボリュームが作りかけた DB のまま、ということ）。違えば、そのあいだに別のホストが同じ DB で
# 店を作ったかもしれないので、やり直さない（やり直すと schema:drop でその店を消す）。
INSTALL_FAILED="$APP_DIR/var/.eccube_install_failed"
# EC-CUBE 4.4 のコンパイル済みテンプレート（var/runtime/<env>/twig）は cache:clear が
# 消さない。本番モードの Twig は更新を見ないので、残すとテンプレートを直しても
# 古い画面が出続ける（bin/plugin.sh の clear_twig_runtime と同じ理由）。
# cache:clear の直前に消す。4.3 以前にはこのディレクトリが無い。
clear_twig_runtime() {
    rm -rf "$APP_DIR"/var/runtime/*/twig 2>/dev/null || true
}
# ECCUBE_SKIP_CACHE_CLEAR=1: cache:clear もスキップする。
# 同一ホストで --scale する際、レプリカは同じ eccube_app ボリューム（var/cache）を
# 共有するため、追加レプリカの cache:clear が稼働中レプリカのコンパイル済み
# コンテナを一瞬消して 500 を出し得る。追加レプリカはこのフラグで何も触らせない。
if [ "${ECCUBE_SKIP_DB_INIT:-0}" = "1" ]; then
    if [ "${ECCUBE_SKIP_CACHE_CLEAR:-0}" = "1" ]; then
        log "scale レプリカ: DB 初期化・cache:clear ともスキップ"
    else
        log "app ロール: DB 初期化/マイグレーションをスキップ（cache:clear のみ）"
        clear_twig_runtime
        runuser -u www-data -- php bin/console cache:clear --no-interaction || true
    fi
else
    # **install するかは、DB を見て決める。** eccube:install は最初に doctrine:schema:drop --force を打つ。
    #   DB が空（店の表が無い）          → install（消すものが無い。印があっても。DB を空にしてやり直す道）
    #   DB に店があり、印がある           → インストール済み（migration とキャッシュ）
    #   DB に店があり、印が無い           → install しない。印を置いて migration へ（新しいホスト・作り直したボリューム）
    #   DB に店があり、失敗の印の指紋が同じ → このボリュームが作りかけた DB なので install をやり直す
    #   DB に店があり、失敗の印があるが指紋が読めない → 何もしない（install も印もなし。次の起動でまた見る）
    #   DB に繋がらない                   → install しない（印があれば、今までどおり migration とキャッシュへ）
    shop=0; db_has_shop || shop=$?
    do_install=0; hold=0
    if [ "$shop" = 1 ]; then
        do_install=1
    elif [ "$shop" = 0 ] && [ -f "$INSTALL_FAILED" ]; then
        # 指紋は**両方とも読めたときだけ**比べる。どちらかが読めない（unknown）なら、同じ DB だとも
        # 違う DB だとも言えないので、install もしないし失敗の印も消さない（次の起動でまた見る）。
        saved="$(cat "$INSTALL_FAILED" 2>/dev/null || true)"
        cur="$(db_shop_stamp)"
        case "$saved|$cur" in
            stamp:?*\|stamp:?*)
                if [ "$saved" = "$cur" ]; then
                    log "前回このボリュームで途中まで進んだインストールを、最初からやり直します（DB はそのときのまま）。"
                    do_install=1
                else
                    log "前回のインストールは途中で失敗しましたが、そのあと DB が変わっています（別のホストが店を作った可能性）。"
                    log "消してしまわないよう、eccube:install はやり直しません。"
                    rm -f "$INSTALL_FAILED"
                fi ;;
            stamp:*\|stamp:?*)
                # 失敗した時点では店の表が無かったのに、いまはある → 別のホストが作った
                log "前回のインストールは途中で失敗しましたが、そのあと別のところで店の表が作られています。"
                log "消してしまわないよう、eccube:install はやり直しません。"
                rm -f "$INSTALL_FAILED"
                ;;
            *)
                hold=1 ;;
        esac
    fi
    if [ "$do_install" = 1 ]; then
        log "eccube:install（初回セットアップ）"
        if runuser -u www-data -- php bin/console eccube:install --no-interaction; then
            rm -f "$INSTALL_FAILED"
            runuser -u www-data -- php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration || true
            clear_twig_runtime
            runuser -u www-data -- php bin/console cache:clear --no-interaction || true
            touch "$MARKER"
            log "セットアップ完了"
            log "管理画面: /${ECCUBE_ADMIN_ROUTE:-admin}/  ログイン ID: ${ECCUBE_ADMIN_USER:-admin}  パスワード: .env の ECCUBE_ADMIN_PASS"
            if [ -z "${ECCUBE_ADMIN_PASS:-}" ] || [ "${ECCUBE_ADMIN_PASS:-}" = "password" ]; then
                log "警告: 管理者が既定の admin / password です。公開前に必ず変えてください（bin/publish.sh は止まります）"
            fi
        else
            rm -f "$MARKER"
            db_shop_stamp > "$INSTALL_FAILED"
            log "eccube:install が失敗しました。ログを確認してください。直して起動し直すと、最初からやり直します。"
        fi
    elif [ "$hold" = 1 ]; then
        log "エラー: 前回のインストールが途中で失敗しています。DB が同じものかを確かめられなかったので、"
        log "消してしまわないよう eccube:install は打たず、インストール済みの印も置きません（起動し直すとまた確かめます）。"
        log "DB に繋がるようにして起動し直してください。それでも続くなら、DB を空にしてから起動し直すと最初からインストールします。"
    elif [ "$shop" = 2 ] && [ ! -f "$MARKER" ]; then
        log "エラー: DB に店があるかを確かめられませんでした（繋がらない）。消してしまわないよう、eccube:install は打ちません。"
        log "DB の設定（DB_HOST / DB_USER / DB_PASSWORD / DB_NAME）を確かめて、コンテナを起動し直してください。"
    else
        # 店がある（0）か、印があって一時的に繋がらない（2。今までどおり migration とキャッシュへ）
        if [ ! -f "$MARKER" ]; then
            log "DB にはもう店があります（dtb_base_info）。eccube:install は打ちません（打つと全部の表を消して作り直します）。"
            log "（別の場所で始めたインストールが途中で止まった DB なら、DB を空にしてから起動し直すと、最初からインストールします）"
            touch "$MARKER"
        fi
        migrate_installed
        # bind-mount した app/config・app/Customize の変更を prod のコンパイル済み
        # コンテナへ反映するため、毎起動でキャッシュを作り直す（dev では無害）。
        clear_twig_runtime
        runuser -u www-data -- php bin/console cache:clear --no-interaction || true
    fi
fi

exec "$@"
