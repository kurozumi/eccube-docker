#!/usr/bin/env bash
# 本番構成で起動する（compose.prod.yaml を使用）。
# 公開方式は .env の COMPOSE_PROFILES で選ぶ（tunnel / caddy / 空=背後配置）。
set -euo pipefail
cd "$(dirname "$0")/.."

# ── シークレットが既定値のまま本番公開するのを防ぐガード ──
# どうしても既定値のまま起動したい場合のみ FORCE_PUBLISH=1 bin/publish.sh
if [ "${FORCE_PUBLISH:-0}" != "1" ] && [ -f .env ]; then
    bad=0
    for pair in \
        "ECCUBE_AUTH_MAGIC=change_this_to_a_random_hex_string" \
        "DB_PASSWORD=eccube_pass" \
        "DB_ROOT_PASSWORD=change_me_root"; do
        if grep -qE "^${pair}$" .env; then
            echo "[publish] エラー: ${pair%%=*} が既定値のままです。"
            bad=1
        fi
    done
    if [ "$bad" = "1" ]; then
        echo "[publish] 本番公開を中止しました。.env のシークレットを固有の値にしてください。"
        echo "          （新規環境なら rm .env && bin/init.sh で自動生成されます。"
        echo "            既定値で DB 初期化済みの場合はデータ再作成が必要: docker compose down -v）"
        echo "          それでも起動する場合: FORCE_PUBLISH=1 bin/publish.sh"
        exit 1
    fi
fi

docker compose -f compose.yaml -f compose.prod.yaml up -d --build
docker compose -f compose.yaml -f compose.prod.yaml ps
