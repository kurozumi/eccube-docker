#!/usr/bin/env bash
# バックアップ（bin/backup.sh の出力）から復元する。
#   使い方:  bin/restore.sh backups/20260721-040000
#
# 戻すもの:
#   db.sql.gz          DB（既存データを DROP して置き換える。確認プロンプトあり）
#   upload.tar.gz      アップロード画像
#   admin-files.tar.gz 管理画面が書いたファイルと git に入らない資産
#                      （app/template・html/user_data 全体・app/Plugin）
#   container.env      **戻さない。** 管理画面が書くキーの差分を出すだけ。
#                      ホストの .env や compose が渡す値と衝突しうるので、人が決める。
#   host.env           **戻さないが、ECCUBE_AUTH_MAGIC が違えば止める。** 全パスワードの
#                      ハッシュの鍵なので、違う値のまま DB を戻すと誰もログインできない。
#
# 引っ越しは「clone → bin/init.sh → bin/restore.sh <退避先>」で完結する。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

# ボリュームは alpine で触る（bin/backup.sh と同じ理由: ec-cube のイメージが
# 無いとフルビルドが始まる）。
proj="$(guard_project_name)"
[ -n "$proj" ] || { echo "[restore] エラー: compose のプロジェクト名を取得できません" >&2; exit 1; }
vol_rw() { # vol_rw <ボリューム名> <マウント先> <コマンド…>
    docker run --rm -i -v "${proj}_$1:$2" alpine:3 "${@:3}"
}

src="${1:-}"

# ── 暗号化されたバックアップ（backup.sh の BACKUP_ENCRYPT_KEY）を透過的に読む ──
# rd <名前> … その名前の平文を標準出力へ。<名前>.enc があれば復号、無ければそのまま。
# 鍵は .env の BACKUP_ENCRYPT_KEY（引っ越し先では退避元の値を先に .env へ写す）。
enc_key="$(env_get BACKUP_ENCRYPT_KEY)"
has() { [ -f "${src}/$1" ] || [ -f "${src}/$1.enc" ]; }
rd() {
    if [ -f "${src}/$1.enc" ]; then
        [ -n "$enc_key" ] || { echo "[restore] エラー: ${src}/$1.enc は暗号化されていますが、.env に BACKUP_ENCRYPT_KEY がありません" >&2; exit 1; }
        BACKUP_ENCRYPT_KEY="$enc_key" openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 600000 \
            -pass env:BACKUP_ENCRYPT_KEY -in "${src}/$1.enc" \
            || { echo "[restore] エラー: $1.enc を復号できません（鍵が違う、または壊れています）" >&2; exit 1; }
    else
        cat "${src}/$1"
    fi
}
if [ -z "$src" ] || ! has db.sql.gz; then
    echo "使い方: bin/restore.sh <バックアップディレクトリ>"
    echo "  例: bin/restore.sh backups/20260721-040000"
    ls -1d backups/*/ 2>/dev/null | sed 's/^/  候補: /' || true
    exit 1
fi

# **DB を戻す前に、ECCUBE_AUTH_MAGIC を突き合わせる。**
# 戻したあとに気づくと「ログインできない」しか症状が無く、DB を疑って時間を溶かす。
# 運搬中に壊れていないか（backup.sh が暗号化後に取ったハッシュ）
if [ -f "${src}/SHA256SUMS" ]; then
    while read -r sum name; do
        [ -f "${src}/${name}" ] || continue
        got="$(openssl dgst -sha256 -r "${src}/${name}" | cut -d' ' -f1)"
        [ "$got" = "$sum" ] || { echo "[restore] エラー: ${name} のハッシュが合いません（運搬中に壊れた可能性）。中止します。" >&2; exit 1; }
    done < "${src}/SHA256SUMS"
fi
if has host.env && [ -f .env ]; then
    # 復号は 1 回にして、以降はこの変数から読む
    host_env="$(rd host.env)"
    was="$(printf '%s\n' "$host_env" | grep -E '^ECCUBE_AUTH_MAGIC=' | head -1 | cut -d= -f2- || true)"
    now="$(grep -E '^ECCUBE_AUTH_MAGIC=' .env | head -1 | cut -d= -f2- || true)"
    if [ -n "$was" ] && [ "$was" != "$now" ]; then
        cat <<EOS >&2
[restore] エラー: ECCUBE_AUTH_MAGIC が退避時と違います。中止します。

  退避時: ${was:0:4}…（${src}/host.env）
  いま  : ${now:0:4}…（.env）

  これは全パスワードのハッシュの鍵です。違う値のまま DB を戻すと、会員も管理者も
  **誰もログインできなくなります**（エラーは出ず、パスワードが違うと言われるだけ）。

  .env の ECCUBE_AUTH_MAGIC を退避時の値に合わせてから、もう一度実行してください:
    sed -i.bak "s|^ECCUBE_AUTH_MAGIC=.*|ECCUBE_AUTH_MAGIC=${was}|" .env
    docker compose up -d
    bin/restore.sh ${src}
EOS
        exit 1
    fi
    # テーマも見ておく。違うと、管理画面で直したメール文面・ブロックの写しが読まれない
    tw="$(printf '%s\n' "$host_env" | grep -E '^ECCUBE_TEMPLATE_CODE=' | head -1 | cut -d= -f2- || true)"
    tn="$(grep -E '^ECCUBE_TEMPLATE_CODE=' .env | head -1 | cut -d= -f2- || true)"
    if [ -n "$tw" ] && [ "$tw" != "${tn:-default}" ]; then
        echo "[restore] 注意: ECCUBE_TEMPLATE_CODE が退避時（${tw}）と違います（いま: ${tn:-default}）。"
        echo "          管理画面で直したメール文面やブロックは app/template/${tw}/ にあり、いまのテーマでは読まれません。"
    fi
fi

echo "[restore] ${src} から復元します。現在の DB は上書きされます。"
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

# DB は手元の db サービスか外部か（bin/backup.sh と同じ判定）
db_engine="$(env_get DB_ENGINE)"; db_engine="${db_engine:-mysql}"
# 外部 DB に繋ぐクライアントの版は、手元の db サービスと同じ変数から（.env の MARIADB_VERSION / PG_VERSION）
mariadb_img="$(env_get MARIADB_IMAGE)"; mariadb_img="${mariadb_img:-mariadb}"
mariadb_ver="$(env_get MARIADB_VERSION)"; mariadb_ver="${mariadb_ver:-10.6}"
pg_ver="$(env_get PG_VERSION)"; pg_ver="${pg_ver:-16}"
db_host="$(env_get DB_HOST)"; db_host="${db_host:-db}"
db_port="$(env_get DB_PORT)"
local_db=0; [ "$db_host" = "db" ] && [ -n "$(docker compose ps -q db 2>/dev/null)" ] && local_db=1
case "$db_engine" in
  postgresql)
    db_port="${db_port:-5432}"
    # pg_dump --clean で作ってあるので、既存の表は DROP されてから作り直される
    if [ "$local_db" = 1 ]; then
        echo "[restore] DB を復元しています（手元の db サービス / PostgreSQL）..."
        rd db.sql.gz | gunzip -c | docker compose exec -T db sh -c \
            'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -q -v ON_ERROR_STOP=0 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
    else
        echo "[restore] DB を復元しています（外部 PostgreSQL: ${db_host}:${db_port}）..."
        rd db.sql.gz | gunzip -c | docker run --rm -i --network "${proj}_backend" -e PGPASSWORD="$(env_get DB_PASSWORD)" "postgres:${pg_ver}-alpine" \
            psql -q -v ON_ERROR_STOP=0 -h "$db_host" -p "$db_port" -U "$(env_get DB_USER)" -d "$(env_get DB_NAME)" >/dev/null
    fi
    ;;
  *)
    db_port="${db_port:-3306}"
    if [ "$local_db" = 1 ]; then
        echo "[restore] DB を復元しています（手元の db サービス）..."
        rd db.sql.gz | gunzip -c | docker compose exec -T db sh -c \
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root "$MYSQL_DATABASE"'
    else
        echo "[restore] DB を復元しています（外部: ${db_host}:${db_port}）..."
        rd db.sql.gz | gunzip -c | docker run --rm -i --network "${proj}_backend" \
            -e MYSQL_PWD="$(env_get DB_PASSWORD)" "${mariadb_img}:${mariadb_ver}" \
            mysql -h "$db_host" -P "$db_port" -u "$(env_get DB_USER)" "$(env_get DB_NAME)"
    fi
    ;;
esac

if has upload.tar.gz; then
    echo "[restore] アップロード画像を復元しています..."
    # 書庫の先頭は upload/ なので、/ に展開すると /upload（＝ボリューム）に重なる。
    # www-data は uid 33（php:*-fpm 系の既定）。alpine には無いので数字で指定する。
    rd upload.tar.gz | vol_rw eccube_upload /upload sh -c 'tar -C / -xzf - && chown -R 33:33 /upload'
fi

if has admin-files.tar.gz; then
    # ホスト側へ展開する（bind mount なのでコンテナからも見える）。
    # 中身は app/template と customize.css/js。git 管理下のパスを上書きするので、
    # 引っ越し先で git が汚れて見えるのは正常（本番で管理画面が書いた分）。
    echo "[restore] 管理画面が書いたファイルと、git に入らない資産を復元しています..."
    rd admin-files.tar.gz | tar -xzf -
    # app/Plugin が戻った。DB は「有効」と言っているので、ファイルが揃った今、
    # プロキシとキャッシュを組み立て直さないと落ちる（下の cache:clear だけでは足りない）。
    need_reload=1
    if has plugins.txt && rd plugins.txt | grep -qv $'\t-$'; then
        echo "[restore] プラグインは .git 抜きで戻しました。git で更新したいものは clone し直してください:"
        rd plugins.txt | grep -v $'\t-$' | awk -F'\t' '{printf "           %-24s %s\n", $1, $2}'
    fi
fi

if has container.env; then
    cenv="$(rd container.env)"
    # 管理画面がコンテナ内 .env に書くキーだけを比べる。
    # 自動で書き戻さない。ECCUBE_ADMIN_ROUTE のように compose が環境変数で渡して
    # いるキーは、書き戻しても効かない（環境変数が勝つ）うえ、本体はその状態を
    # 「上書きされている」と警告する。
    cur="$(docker run --rm -v "${proj}_eccube_app:/app:ro" alpine:3 cat /app/.env 2>/dev/null || true)"
    diffs=""
    for k in ECCUBE_TEMPLATE_CODE ECCUBE_FRONT_ALLOW_HOSTS ECCUBE_FRONT_DENY_HOSTS \
             ECCUBE_ADMIN_ALLOW_HOSTS ECCUBE_ADMIN_DENY_HOSTS ECCUBE_FORCE_SSL TRUSTED_HOSTS; do
        was="$(printf '%s\n' "$cenv" | grep -E "^${k}=" | head -1 | cut -d= -f2- || true)"
        now="$(printf '%s\n' "$cur" | grep -E "^${k}=" | head -1 | cut -d= -f2- || true)"
        if [ -n "$was" ] && [ "$was" != "$now" ]; then
            diffs="${diffs}    ${k}=${was}   （いま: ${now:-未設定}）\n"
        fi
    done
    if [ -n "$diffs" ]; then
        echo "[restore] 注意: 管理画面がコンテナ内 .env に書いていた値が、いまの環境と違います:"
        printf '%b' "$diffs"
        echo "           必要なら .env（ホスト）に書いて docker compose up -d してください。"
        echo "           テーマ（ECCUBE_TEMPLATE_CODE）は .env に書くのが正です（管理画面の選択は upgrade で消えます）。"
    fi
fi

if [ "${need_reload:-0}" = 1 ]; then
    echo "[restore] プラグインの実体が戻ったので、キャッシュを組み立て直します（数分。止めないでください）..."
    bin/plugin.sh reload || echo "[restore] 注意: reload に失敗しました。bin/plugin.sh doctor を実行してください" >&2
else
    echo "[restore] キャッシュをクリアしています..."
    docker compose exec -T ec-cube runuser -u www-data -- php bin/console cache:clear --no-interaction >/dev/null 2>&1 || true
fi

echo "[restore] 完了。bin/healthcheck.sh で動作確認してください。"
