#!/usr/bin/env bash
# DB とアップロード画像のバックアップ。
#   使い方:  bin/backup.sh                  # ./backups/<日時>/ に保存
#            BACKUP_DIR=/mnt/nas bin/backup.sh   # 保存先を変える
#            BACKUP_KEEP=14 bin/backup.sh        # 保持世代数（既定 7）
#   cron 例（毎日 4:00、リポジトリ直下で）:
#     0 4 * * * cd /path/to/eccube-docker && bin/backup.sh >> var/backup.log 2>&1
#
# - DB は mysqldump --single-transaction（InnoDB 前提・サービス無停止で整合ダンプ）
# - 画像は html/upload を tar.gz（eccube_upload ボリュームの実体）
# - パスワードは MYSQL_PWD で渡し、プロセスリストに露出させない
set -euo pipefail
cd "$(dirname "$0")/.."

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
stamp="$(date +%Y%m%d-%H%M%S)"
dest="${BACKUP_DIR}/${stamp}"
mkdir -p "$dest"

echo "[backup] DB をダンプしています..."
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump \
    --single-transaction --routines --triggers --events \
    -u root "$MYSQL_DATABASE"' | gzip > "${dest}/db.sql.gz"

echo "[backup] アップロード画像を退避しています..."
docker compose exec -T ec-cube tar -C /var/www/html/html -czf - upload > "${dest}/upload.tar.gz"

# 中身の妥当性を軽く確認（空ダンプ・壊れた tar を検知）
gzip -t "${dest}/db.sql.gz"
gzip -t "${dest}/upload.tar.gz"
db_size=$(wc -c < "${dest}/db.sql.gz")
if [ "$db_size" -lt 1024 ]; then
    echo "[backup] エラー: DB ダンプが小さすぎます（${db_size} bytes）。失敗の可能性。" >&2
    exit 1
fi

echo "[backup] 完了: ${dest}"
ls -lh "$dest"

# 世代管理: 古いバックアップを削除（BACKUP_KEEP 世代残す）
# head -n -N は BSD/macOS 非対応のため、削除数を計算して先頭から消す
total=$(ls -1d "${BACKUP_DIR}"/*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$total" -gt "$BACKUP_KEEP" ]; then
    ls -1d "${BACKUP_DIR}"/*/ | sort | head -n $((total - BACKUP_KEEP)) | while read -r old; do
        echo "[backup] 古い世代を削除: ${old}"
        rm -rf "$old"
    done
fi
