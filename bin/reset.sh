#!/usr/bin/env bash
# DB を初期状態へ戻す（ボリュームを破棄して再構築・再インストール）。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[reset] DB とアプリのデータを破棄して作り直します。"
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

docker compose down -v
docker compose up -d --build
echo "[reset] 完了。進捗: docker compose logs -f ec-cube"
