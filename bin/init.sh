#!/usr/bin/env bash
# 初回セットアップ: .env 作成 → ECCUBE_AUTH_MAGIC 生成 → ビルド＆起動。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
    cp .env.example .env
    echo "[init] .env を作成しました"
fi

# ECCUBE_AUTH_MAGIC が未設定/プレースホルダなら生成する
current="$(grep -E '^ECCUBE_AUTH_MAGIC=' .env | head -1 | cut -d= -f2- || true)"
case "$current" in
    "" | change_this_to_a_random_hex_string)
        magic="$(openssl rand -hex 16)"
        tmp="$(mktemp)"
        sed "s|^ECCUBE_AUTH_MAGIC=.*|ECCUBE_AUTH_MAGIC=${magic}|" .env > "$tmp" && mv "$tmp" .env
        echo "[init] ECCUBE_AUTH_MAGIC を生成しました"
        ;;
esac

echo "[init] ビルドして起動します（初回は EC-CUBE 取得で数分かかります）..."
docker compose up -d --build

echo "[init] 進捗確認: docker compose logs -f ec-cube"
echo "[init] フロント: http://localhost:${HTTP_PORT:-8080}/   管理: http://localhost:${HTTP_PORT:-8080}/admin/"
