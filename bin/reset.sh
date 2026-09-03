#!/usr/bin/env bash
# DB を初期状態へ戻す（ボリュームを破棄して再構築・再インストール）。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"

guard_destructive reset.sh "DB・アップロード画像・セッション"

docker compose down -v
docker compose up -d --build
echo "[reset] 完了。進捗: docker compose logs -f ec-cube"
