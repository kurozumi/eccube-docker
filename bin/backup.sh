#!/usr/bin/env bash
# 引っ越し・切り戻しに要るものを 1 か所に集める。
#   使い方:  bin/backup.sh                  # ./backups/<日時>/ に保存
#            BACKUP_DIR=/mnt/nas bin/backup.sh   # 保存先を変える
#            BACKUP_KEEP=14 bin/backup.sh        # 保持世代数（既定 7）
#   cron 例（毎日 4:00、リポジトリ直下で）:
#     0 4 * * * cd /path/to/eccube-docker && bin/backup.sh >> var/backup.log 2>&1
#
# - DB は mysqldump --single-transaction（InnoDB 前提・サービス無停止で整合ダンプ）
# - 画像は html/upload を tar.gz（eccube_upload ボリュームの実体）
# - **管理画面がディスクに書いたもの・git に入らない店の資産**を admin-files.tar.gz に（下の説明）
# - コンテナ内の .env を container.env に（テーマ切替とセキュリティ設定の書き先）
# - **ホストの .env を host.env に。** ECCUBE_AUTH_MAGIC が入っている。これは全パスワードの
#   ハッシュの鍵（PasswordHasher の salt / HMAC 鍵）で、**失うと会員も管理者も全員ログイン
#   できなくなる。** DB を持っていっても、これが違えば意味が無い。
# - パスワードは MYSQL_PWD で渡し、プロセスリストに露出させない
#
# 原則: **ディスクに残る状態は、git か backup のどちらかに必ず入る。**
# これが崩れると「DB には行があるのにファイルが無い」形で引っ越し後に壊れる。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

# ボリュームの中身は **alpine で読む。** ec-cube のイメージで `docker compose run`
# すると、イメージが無いときにフルビルドが始まる（composer で本体取得、数分）。
# バックアップは「イメージが壊れている・無い」状況でこそ要るので、依存させない。
proj="$(guard_project_name)"
[ -n "$proj" ] || { echo "[backup] エラー: compose のプロジェクト名を取得できません" >&2; exit 1; }
# busybox の tar には --transform が無いので、書庫の先頭（upload/）はマウント先の
# 名前で作る。従来の書庫と同じ形になり、古いバックアップもそのまま戻せる。
vol() { # vol <ボリューム名> <マウント先> <コマンド…>
    docker run --rm -v "${proj}_$1:$2:ro" alpine:3 "${@:3}"
}

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
stamp="$(date +%Y%m%d-%H%M%S)"
dest="${BACKUP_DIR}/${stamp}"
mkdir -p "$dest"

# DB は 2 通り。手元の db サービス（単一ホスト）か、外部の DB（compose.app.yaml の
# 複数ホスト、マネージド DB）。外部のときは db コンテナが無いので exec できない。
# **同じ mariadb イメージの使い捨てコンテナから、.env の DB_* で繋ぐ。** compose の
# ネットワークに入れておけば、別スタックの DB 名でもマネージド DB のホスト名でも引ける。
# 外部は root ではなくアプリのユーザーなので --routines / --events は付けない
# （SHOW ROUTINE 等の権限が無いと落ちる。EC-CUBE はどちらも使わない）。
# **対応は MariaDB / MySQL と PostgreSQL。** .env の DB_ENGINE で決まり、mysqldump / pg_dump を
# 使い分ける（restore.sh も同じ判定）。ダンプは種類をまたいで戻らない。
db_engine="$(env_get DB_ENGINE)"; db_engine="${db_engine:-mysql}"
# 外部 DB に繋ぐクライアントの版は、手元の db サービスと同じ変数から（.env の MARIADB_VERSION / PG_VERSION）
mariadb_img="$(env_get MARIADB_IMAGE)"; mariadb_img="${mariadb_img:-mariadb}"
mariadb_ver="$(env_get MARIADB_VERSION)"; mariadb_ver="${mariadb_ver:-10.6}"
pg_ver="$(env_get PG_VERSION)"; pg_ver="${pg_ver:-16}"
db_host="$(env_get DB_HOST)"; db_host="${db_host:-db}"
db_port="$(env_get DB_PORT)"
local_db=0; [ "$db_host" = "db" ] && [ -n "$(docker compose ps -q db 2>/dev/null)" ] && local_db=1
# ダンプの形式はエンジンで違う（restore.sh が同じ判定で読む）。db.sql.gz の名前は共通。
case "$db_engine" in
  postgresql)
    db_port="${db_port:-5432}"
    if [ "$local_db" = 1 ]; then
        echo "[backup] DB をダンプしています（手元の db サービス / PostgreSQL）..."
        docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"' \
            | gzip > "${dest}/db.sql.gz"
    else
        echo "[backup] DB をダンプしています（外部 PostgreSQL: ${db_host}:${db_port}）..."
        docker run --rm --network "${proj}_default" -e PGPASSWORD="$(env_get DB_PASSWORD)" "postgres:${pg_ver}-alpine" \
            pg_dump --clean --if-exists -h "$db_host" -p "$db_port" -U "$(env_get DB_USER)" "$(env_get DB_NAME)" \
            | gzip > "${dest}/db.sql.gz"
    fi
    ;;
  *)
    db_port="${db_port:-3306}"
    if [ "$local_db" = 1 ]; then
        echo "[backup] DB をダンプしています（手元の db サービス）..."
        docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump \
            --single-transaction --routines --triggers --events \
            -u root "$MYSQL_DATABASE"' | gzip > "${dest}/db.sql.gz"
    else
        echo "[backup] DB をダンプしています（外部: ${db_host}:${db_port}）..."
        docker run --rm --network "${proj}_default" \
            -e MYSQL_PWD="$(env_get DB_PASSWORD)" "${mariadb_img}:${mariadb_ver}" mysqldump \
            --single-transaction --triggers --no-tablespaces \
            -h "$db_host" -P "$db_port" -u "$(env_get DB_USER)" "$(env_get DB_NAME)" \
            | gzip > "${dest}/db.sql.gz"
    fi
    ;;
esac

# exec ではなく使い捨てコンテナで読む。exec は ec-cube が起動中でないと失敗し、
# 「アップグレードに失敗してサイトが落ちている状態から復旧したい」ときに
# バックアップが取れなくなる。
echo "[backup] アップロード画像を退避しています..."
vol eccube_upload /upload tar -C / -czf - upload > "${dest}/upload.tar.gz"

# 管理画面がディスクに書いたものを退避する。
#
# 本体の管理画面は DB だけでなくファイルも書く:
#   CSS 管理 / JS 管理  → html/user_data/assets/{css,js}/customize.*
#   ページ管理（新規）  → app/template/user_data/*.twig（dtb_page の行と対）
#   ブロック管理        → app/template/<テーマ>/Block/*.twig
# どれも bind mount なのでホストにはあるが、**git 管理下のパスでも、本番で
# 書かれた分はコミットされていない**。DB と画像だけで引っ越すと、dtb_page には
# 行があるのに twig が無い、という壊れ方をする。ホスト側で直接 tar する。
# 範囲は「git に入らないが、無いと店が壊れるもの」まで広げる:
#   html/user_data 全体 … css/js だけでなく、差し替えた favicon（assets/img）と
#                        納品書のロゴ（assets/pdf）。.gitignore で外してあるので git には無い
#   app/Plugin          … オーナーズストアで買ったプラグインは git に無い。DB は「有効」と
#                        言っているのにファイルが無い、という壊れ方になる
# プラグインの .git は外す。実測で 160MB のうち 112MB が .git で、毎日 7 世代残すと
# それだけで 800MB になる。ソースは入るので店は壊れない。git で入れたものは remote を
# plugins.txt に控えておき、必要なら clone し直せるようにする。
echo "[backup] 管理画面が書いたファイルと、git に入らない資産を退避しています..."
tar -czf "${dest}/admin-files.tar.gz" \
    --exclude='app/Plugin/*/.git' \
    app/template \
    html/user_data \
    app/Plugin
for d in app/Plugin/*/; do
    [ -d "$d" ] || continue
    code="$(basename "$d")"
    url="$(git -C "$d" remote get-url origin 2>/dev/null || echo '-')"
    printf '%s\t%s\n' "$code" "$url"
done > "${dest}/plugins.txt"

# コンテナ内の .env。テーマ切替（オーナーズストア → テンプレート管理）と
# セキュリティ設定の一部は、ホストの .env ではなく**コンテナ内の
# /var/www/html/.env** に書かれる。そこは eccube_app ボリュームの中で、
# bin/upgrade.sh がボリュームを作り直すと消える。
# 復元は自動ではしない（ホストの .env や compose が渡す値と衝突しうる）。
# bin/restore.sh が差分を出す。
if ! vol eccube_app /app cat /app/.env > "${dest}/container.env" 2>/dev/null; then
    echo "[backup] 注意: コンテナ内の .env を読めませんでした（ボリュームが無い？）"
    rm -f "${dest}/container.env"
fi

# ホストの .env。**引っ越しで一番落としやすく、一番致命的。** ECCUBE_AUTH_MAGIC が
# 全パスワードのハッシュの鍵なので、新しいサーバーで違う値にすると DB を戻しても
# 誰もログインできない。バックアップは DB ダンプ（顧客データ）が入る場所なので、
# ここに置く危険は増えない。読める人を絞る。
if [ -f .env ]; then
    cp .env "${dest}/host.env" && chmod 600 "${dest}/host.env"
fi

# git 管理下なら、コミットされていない「管理画面が書いた分」を見せておく。
# backup には入っているので失われはしないが、git にも残すかは人が決めること。
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty="$(git status --porcelain -- app/template html/user_data/assets/css html/user_data/assets/js 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
        echo "[backup] 注意: 管理画面が書いたと思われる、コミットされていない変更があります:"
        printf '%s\n' "$dirty" | sed 's/^/           /'
        echo "           admin-files.tar.gz には入っています。git にも残すならコミットしてください。"
    fi
fi

# 中身の妥当性を軽く確認（空ダンプ・壊れた tar を検知）
gzip -t "${dest}/db.sql.gz"
gzip -t "${dest}/upload.tar.gz"
gzip -t "${dest}/admin-files.tar.gz"
db_size=$(wc -c < "${dest}/db.sql.gz")
if [ "$db_size" -lt 1024 ]; then
    echo "[backup] エラー: DB ダンプが小さすぎます（${db_size} bytes）。失敗の可能性。" >&2
    exit 1
fi

echo "[backup] 完了: ${dest}"
ls -lh "$dest"

# サーバーの外へ出す。**backups/ は同じディスクにあるので、サーバーごと失うと一緒に消える。**
# .env の BACKUP_SYNC に送り先を書くと、ここで送る。送れなければ失敗にする
# （黙って飛ばすと「取れているつもり」になる。それが一番危ない）。
#   BACKUP_SYNC=rclone:<remote>:<bucket>/<path>   … rclone（S3 / R2 / Drive / NAS）
#   BACKUP_SYNC=<user>@<host>:<path>               … rsync over ssh
#   BACKUP_SYNC=/mnt/nas/eccube                    … rsync（マウント済みの NAS）
sync_to="$(env_get BACKUP_SYNC)"
if [ -n "$sync_to" ]; then
    name="$(basename "$dest")"
    case "$sync_to" in
        rclone:*)
            command -v rclone >/dev/null 2>&1 || { echo "[backup] エラー: BACKUP_SYNC が rclone ですが rclone がありません" >&2; exit 1; }
            echo "[backup] サーバーの外へ送ります（rclone）: ${sync_to#rclone:}/${name}"
            rclone copy "$dest" "${sync_to#rclone:}/${name}" || { echo "[backup] エラー: 外へ送れませんでした" >&2; exit 1; }
            ;;
        *)
            command -v rsync >/dev/null 2>&1 || { echo "[backup] エラー: BACKUP_SYNC が rsync ですが rsync がありません" >&2; exit 1; }
            echo "[backup] サーバーの外へ送ります（rsync）: ${sync_to}/${name}"
            rsync -a "$dest" "${sync_to}/" || { echo "[backup] エラー: 外へ送れませんでした" >&2; exit 1; }
            ;;
    esac
fi

# 世代管理: 古いバックアップを削除（BACKUP_KEEP 世代残す）
# head -n -N は BSD/macOS 非対応のため、削除数を計算して先頭から消す
total=$(ls -1d "${BACKUP_DIR}"/*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$total" -gt "$BACKUP_KEEP" ]; then
    ls -1d "${BACKUP_DIR}"/*/ | sort | head -n $((total - BACKUP_KEEP)) | while read -r old; do
        echo "[backup] 古い世代を削除: ${old}"
        rm -rf "$old"
    done
fi
