#!/usr/bin/env bash
# バックアップ（bin/backup.sh の出力）から復元する。
#   使い方:  bin/restore.sh backups/20260721-040000
#
# **戻す前に、いまの状態を退避する**（backups/<日時>-before-restore/）。退避できなければ何も変えずに
# 止まる。戻している途中で失敗したら、その退避から自動で元に戻す。戻している間はメンテナンス表示。
#   いまの DB が壊れていて退避が取れないときだけ: RESTORE_WITHOUT_BACKUP=<プロジェクト名> bin/restore.sh …
#   確認を打たずに進める（スクリプトから）:       CONFIRM_RESTORE=<プロジェクト名> bin/restore.sh …
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
set -Eeuo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
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

# --rollback は restore.sh 自身と upgrade.sh が失敗の後始末に使う（確認・退避・メンテナンスを親に任せる）
# --db-only は DB だけ戻す（upgrade.sh の切り戻し。アプリは止まっていて、画像とファイルは触っていない）
rollback=0; db_only=0
while :; do
    case "${1:-}" in
        --rollback) rollback=1; shift ;;
        --db-only)  db_only=1; shift ;;
        *) break ;;
    esac
done
[ "$db_only" = 0 ] || [ "$rollback" = 1 ] || { echo "[restore] エラー: --db-only は --rollback と一緒にだけ使えます（内部用）" >&2; exit 1; }
src="${1:-}"
src="${src%/}"

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
# **ダンプが最後まであるかを、何かを変える前に見る。** 途中で切れたダンプを流すと、psql は入力の終わりを
# 正常な終わりとみなしてそこまでを確定する（表を消して作り直したところで切れていれば、空の表で「完了」）。
# mysqldump / pg_dump は最後に完了の行を書くので、それがあるかで判る。
if ! rd db.sql.gz | gunzip -c | tail -c 1024 | grep -qE -- '-- (PostgreSQL database dump complete|Dump completed)'; then
    echo "[restore] エラー: ${src} の DB ダンプが最後までありません（途中で切れている・壊れている）。何も変えずに中止します。" >&2
    exit 1
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

if [ "$rollback" = 0 ]; then
    echo "[restore] ${src} から復元します。現在の DB・画像・管理画面が書いたファイルは上書きされます。"
    echo "          （その前に、いまの状態を backups/ へ退避します）"
    if [ -n "${CONFIRM_RESTORE:-}" ]; then
        [ "$CONFIRM_RESTORE" = "$proj" ] || { echo "[restore] エラー: CONFIRM_RESTORE がプロジェクト名（${proj}）と違います。中止します。" >&2; exit 1; }
    else
        read -r -p "続行しますか? [y/N] " ans
        [ "$ans" = "y" ] || { echo "中止しました"; exit 1; }
    fi
fi

# ── 同じプロジェクトで restore を同時に走らせない ──
# 重なると、あとの restore が先の restore のメンテナンス表示を「前回の残り」とみなして引き取り、
# どちらかが、もう一方が DB を書き換えている最中に表示を外してしまう。内部の --rollback は親の鍵のまま動く。
lock="var/restore.lock"
if [ "$rollback" = 0 ]; then
    mkdir -p var
    if ! mkdir "$lock" 2>/dev/null; then
        other="$(cat "$lock/pid" 2>/dev/null || true)"
        if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
            echo "[restore] エラー: ほかの restore が動いています（pid ${other}）。終わってからやり直してください。" >&2
            exit 1
        fi
        echo "[restore] 前の restore の鍵が残っていました（pid ${other:-?} はもういません）。引き取ります。"
        rm -rf "$lock"; mkdir "$lock"
    fi
    echo "$$" > "$lock/pid"
    trap 'rm -rf "$lock"' EXIT
fi

# ── メンテナンス表示。**退避を取る前に立てる。** ──
# 退避を取り始めてから表示を立てるまでに入った注文は、退避に無い。戻すのに失敗して退避から戻すと、
# その注文が消える。立てられなければ何も変えずに止める（お客さんが注文できる状態で DB を書き換えない）。
# deploy.sh と同じ仕組み。restore: を付けたものだけ自分で消す。手で入れたものは残す。
MAINT=/var/www/html/.maintenance
maint_mine=0
if [ "$rollback" = 0 ] && [ -n "$(docker compose ps -q --status running ec-cube 2>/dev/null)" ]; then
    if docker compose exec -T ec-cube sh -c "grep -q '^restore:' $MAINT" 2>/dev/null; then
        maint_mine=1   # 前の restore が失敗して残したもの（鍵を取れたので、動いている restore のものではない）
        echo "[restore] メンテナンス表示は前回の restore から ON のままです（そのまま進めます）"
    elif docker compose exec -T ec-cube test -f "$MAINT" 2>/dev/null; then
        echo "[restore] メンテナンス表示はすでに有効です（手で入れたもの。終わっても外しません）"
    elif docker compose exec -T ec-cube runuser -u www-data -- sh -c "printf 'restore:%s' '$(openssl rand -hex 16)' > $MAINT"; then
        maint_mine=1
        echo "[restore] メンテナンス ON（お客さんには「メンテナンス中」）"
    else
        echo "[restore] エラー: メンテナンス表示を立てられませんでした。注文を受けたまま DB を書き換えないよう、何も変えずに中止します。" >&2
        exit 1
    fi
fi
maint_off() {
    if [ "$maint_mine" = 1 ] && docker compose exec -T ec-cube sh -c "grep -q '^restore:' $MAINT" 2>/dev/null; then
        docker compose exec -T ec-cube rm -f "$MAINT" && echo "[restore] メンテナンス OFF"
    fi
}

# ── いまの状態を退避する。できなければ何も変えずに止める ──
# 戻す元を間違えた・古すぎた、というときに戻れる場所がここしか無い。backup.sh の世代管理が
# 「いまから戻す元」を押し出さないよう、BACKUP_PROTECT で守る。
safety=""
if [ "$rollback" = 0 ]; then
    if [ -n "${RESTORE_WITHOUT_BACKUP:-}" ]; then
        [ "$RESTORE_WITHOUT_BACKUP" = "$proj" ] || { echo "[restore] エラー: RESTORE_WITHOUT_BACKUP がプロジェクト名（${proj}）と違います。中止します。" >&2; exit 1; }
        echo "[restore] 注意: RESTORE_WITHOUT_BACKUP が付いているので、いまの状態を退避せずに戻します（失敗しても自動では戻せません）。"
    else
        echo "[restore] 戻す前に、いまの状態を退避します..."
        rf="$(mktemp)"
        if ! BACKUP_LABEL=restore BACKUP_PROTECT="$src" BACKUP_RESULT_FILE="$rf" bin/backup.sh >"${rf}.log" 2>&1; then
            tail -5 "${rf}.log" >&2; rm -f "$rf" "${rf}.log"
            maint_off
            cat >&2 <<EOS
[restore] エラー: いまの状態を退避できませんでした。**何も変えずに中止します。**
          bin/backup.sh を単体で打って原因を見てください。
          いまの DB が壊れていて退避できない、と分かっているときだけ:
            RESTORE_WITHOUT_BACKUP=${proj} bin/restore.sh ${src}
EOS
            exit 1
        fi
        safety="$(cat "$rf")"; rm -f "$rf" "${rf}.log"
        echo "[restore] 退避しました: ${safety}"
    fi
fi

# ── 途中で失敗したら、退避から元に戻す ──
on_fail() {
    # set -E なので、パイプの中の子プロセスでも呼ばれる。戻すのは親だけ（子でも戻すと 2 回戻す）
    [ "${BASH_SUBSHELL:-0}" = 0 ] || exit 1
    trap - ERR
    echo >&2
    if [ "$rollback" = 1 ]; then
        echo "[restore] 元に戻す途中でも失敗しました。" >&2
        exit 1
    fi
    if [ -z "$safety" ]; then
        echo "[restore] 失敗しました。退避を取っていないので、自動では戻せません（RESTORE_WITHOUT_BACKUP）。" >&2
        echo "          メンテナンス表示は ON のままです。" >&2
        exit 1
    fi
    echo "[restore] 失敗しました。戻す前に取った退避（${safety}）から、元の状態に戻します..." >&2
    if bin/restore.sh --rollback "$safety"; then
        maint_off
        echo "[restore] **元の状態に戻しました。** ${src} は戻せていません。上のエラーを見てください。" >&2
    else
        cat >&2 <<EOS
[restore] **元に戻すのにも失敗しました。メンテナンス表示は ON のままです。**
          いまの状態の退避はここにあります（消さないでください）: ${safety}
          原因を直してから、これを戻してください:  bin/restore.sh ${safety}
          （直す前にお店を開けるなら: docker compose exec ec-cube rm /var/www/html/.maintenance）
EOS
    fi
    exit 1
}
trap on_fail ERR

# DB は手元の db サービスか外部か（bin/backup.sh と同じ判定）
db_engine="$(env_get DB_ENGINE)"; db_engine="${db_engine:-mysql}"
# 外部 DB に繋ぐクライアントの版は、手元の db サービスと同じ変数から（.env の MARIADB_VERSION / PG_VERSION）
mariadb_img="$(env_get MARIADB_IMAGE)"; mariadb_img="${mariadb_img:-mariadb}"
mariadb_ver="$(env_get MARIADB_VERSION)"; mariadb_ver="${mariadb_ver:-10.11}"
pg_ver="$(env_get PG_VERSION)"; pg_ver="${pg_ver:-16}"
db_host="$(env_get DB_HOST)"; db_host="${db_host:-db}"
db_port="$(env_get DB_PORT)"
local_db=0; [ "$db_host" = "db" ] && [ -n "$(docker compose ps -q db 2>/dev/null)" ] && local_db=1
# **ダンプを流す前に、いまある表を全部消す。** ダンプは自分が持つ表しか作り直さないので、退避した
# あとで増えた表（upgrade の途中で作られた新しい版の表など）がそのまま残り、「その時点に戻した」ことに
# ならない。いまの状態は上で退避してある（RESTORE_WITHOUT_BACKUP のときを除く）。
# MySQL の GROUP_CONCAT は既定で 1024 バイトで切れる（表は 60 個を超える）ので、先に広げる。
read -r -d '' my_clear <<'SQL' || true
SET SESSION group_concat_max_len = 1048576;
SET FOREIGN_KEY_CHECKS = 0;
SET @v = (SELECT GROUP_CONCAT('`', table_name, '`') FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'VIEW');
SET @s = IF(@v IS NULL, 'DO 0', CONCAT('DROP VIEW IF EXISTS ', @v));
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @t = (SELECT GROUP_CONCAT('`', table_name, '`') FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE');
SET @s = IF(@t IS NULL, 'DO 0', CONCAT('DROP TABLE IF EXISTS ', @t));
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SQL
# PostgreSQL はダンプと同じトランザクションの中で消す（失敗すれば消したことも取り消される）
read -r -d '' pg_clear <<'SQL' || true
DO $$ DECLARE r record; BEGIN
  -- 拡張が持つもの（pg_stat_statements のビューなど）は単独では消せない（CASCADE でも拒まれる）ので除く。
  -- ダンプの CREATE EXTENSION が扱う
  FOR r IN SELECT c.relname AS n, c.relkind AS k FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
      WHERE ns.nspname = current_schema() AND c.relkind IN ('v', 'm', 'r', 'p', 'S')
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
      ORDER BY CASE c.relkind WHEN 'v' THEN 0 WHEN 'm' THEN 0 WHEN 'S' THEN 2 ELSE 1 END
  LOOP
    EXECUTE format('DROP %s IF EXISTS %I CASCADE',
      CASE r.k WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, r.n);
  END LOOP;
END $$;
SQL
dump_with() { # dump_with <先に流す SQL> … それに続けてダンプの平文を標準出力へ
    printf '%s\n' "$1"
    rd db.sql.gz | gunzip -c
}
case "$db_engine" in
  postgresql)
    db_port="${db_port:-5432}"
    # pg_dump --clean で作ってあるので、既存の表は DROP されてから作り直される。
    # **1 つのトランザクションで流し、エラーで止める。** 以前は ON_ERROR_STOP=0 で、途中で失敗しても
    # 残りを流して「完了」と出していた。いまは失敗すれば DB は流す前のまま。
    if [ "$local_db" = 1 ]; then
        echo "[restore] DB を復元しています（手元の db サービス / PostgreSQL）..."
        dump_with "$pg_clear" | docker compose exec -T db sh -c \
            'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
    else
        echo "[restore] DB を復元しています（外部 PostgreSQL: ${db_host}:${db_port}）..."
        dump_with "$pg_clear" | docker run --rm -i --network "${proj}_backend" -e PGPASSWORD="$(env_get DB_PASSWORD)" "postgres:${pg_ver}-alpine" \
            psql -q -v ON_ERROR_STOP=1 --single-transaction -h "$db_host" -p "$db_port" -U "$(env_get DB_USER)" -d "$(env_get DB_NAME)" >/dev/null
    fi
    ;;
  *)
    db_port="${db_port:-3306}"
    if [ "$local_db" = 1 ]; then
        echo "[restore] DB を復元しています（手元の db サービス）..."
        dump_with "$my_clear" | docker compose exec -T db sh -c \
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root "$MYSQL_DATABASE"'
    else
        echo "[restore] DB を復元しています（外部: ${db_host}:${db_port}）..."
        dump_with "$my_clear" | docker run --rm -i --network "${proj}_backend" \
            -e MYSQL_PWD="$(env_get DB_PASSWORD)" "${mariadb_img}:${mariadb_ver}" \
            mysql -h "$db_host" -P "$db_port" -u "$(env_get DB_USER)" "$(env_get DB_NAME)"
    fi
    ;;
esac

if [ "$db_only" = 1 ]; then
    trap - ERR
    echo "[restore] DB を戻しました（DB だけ）。"
    exit 0
fi

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
    # `._*` は展開しない。v1.0.10 以前の macOS で取った書庫には AppleDouble（拡張属性の
    # 別ファイル）が入っていて、Linux で展開すると `._customize.css` などが実ファイルの隣に
    # 並び、中身のバイナリが画面の先頭に出る。取る側は直した（COPYFILE_DISABLE=1）が、
    # 既に作った書庫は直せないので、展開側でも落とす。
    rd admin-files.tar.gz | tar -xzf - --exclude='._*'
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
    if ! bin/plugin.sh reload; then
        # 元に戻している最中なら、失敗として親へ返す（親はメンテナンス表示を外さず、戻し切れなかったと伝える）
        if [ "$rollback" = 1 ] && [ -n "$(docker compose ps -q --status running ec-cube 2>/dev/null)" ]; then
            echo "[restore] キャッシュを組み立て直せませんでした。" >&2
            exit 1
        fi
        echo "[restore] 注意: reload に失敗しました。bin/plugin.sh doctor を実行してください" >&2
    fi
else
    echo "[restore] キャッシュをクリアしています..."
    docker compose exec -T ec-cube runuser -u www-data -- php bin/console cache:clear --no-interaction >/dev/null 2>&1 || true
fi

trap - ERR
[ "$rollback" = 1 ] && exit 0
maint_off
echo "[restore] 完了。bin/healthcheck.sh で動作確認してください。"
[ -n "$safety" ] && echo "          戻す前の状態はここに退避してあります: ${safety}（戻すなら bin/restore.sh ${safety}）"
exit 0
