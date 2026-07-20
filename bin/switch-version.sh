#!/usr/bin/env bash
# EC-CUBE のバージョンを切り替える。スキーマが変わるため DB とアプリのボリュームを作り直す。
#   使い方: bin/switch-version.sh ~4.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

ver="${1:-}"
if [ -z "$ver" ]; then
    echo "使い方: bin/switch-version.sh <制約>   例: ~4.3.0 / ~4.2.0 / ~4.1.0"
    exit 1
fi

echo "[switch] ECCUBE_VERSION=${ver} に切り替えます。既存の DB とアプリのデータは破棄されます。"
echo "[switch] 注意: アップロード画像（eccube_upload）も削除されます。残したい場合は先にバックアップを:"
echo "         docker compose cp ec-cube:/var/www/html/html/upload/. ./upload-backup/"
echo "         （NFS/EFS ドライバで運用していれば外部データは消えません）"
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

if grep -qE '^ECCUBE_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^ECCUBE_VERSION=.*|ECCUBE_VERSION=${ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "ECCUBE_VERSION=${ver}" >> .env
fi

docker compose down -v
docker compose up -d --build
echo "[switch] 完了。進捗: docker compose logs -f ec-cube"
