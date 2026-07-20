#!/usr/bin/env bash
# バックアップ（bin/backup.sh の出力）から DB とアップロード画像を復元する。
#   使い方:  bin/restore.sh backups/20260721-040000
#
# 注意: DB は既存データを DROP して置き換える。実行前に確認プロンプトあり。
set -euo pipefail
cd "$(dirname "$0")/.."

src="${1:-}"
if [ -z "$src" ] || [ ! -f "${src}/db.sql.gz" ]; then
    echo "使い方: bin/restore.sh <バックアップディレクトリ>"
    echo "  例: bin/restore.sh backups/20260721-040000"
    ls -1d backups/*/ 2>/dev/null | sed 's/^/  候補: /' || true
    exit 1
fi

echo "[restore] ${src} から復元します。現在の DB は上書きされます。"
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

echo "[restore] DB を復元しています..."
gunzip -c "${src}/db.sql.gz" | docker compose exec -T db sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root "$MYSQL_DATABASE"'

if [ -f "${src}/upload.tar.gz" ]; then
    echo "[restore] アップロード画像を復元しています..."
    docker compose exec -T ec-cube tar -C /var/www/html/html -xzf - < "${src}/upload.tar.gz"
    docker compose exec -T ec-cube chown -R www-data:www-data /var/www/html/html/upload
fi

echo "[restore] キャッシュをクリアしています..."
docker compose exec -T ec-cube runuser -u www-data -- php bin/console cache:clear --no-interaction >/dev/null 2>&1 || true

echo "[restore] 完了。bin/healthcheck.sh で動作確認してください。"
