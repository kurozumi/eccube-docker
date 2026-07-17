#!/usr/bin/env bash
# 本番構成で起動する（compose.prod.yaml を使用）。
# 公開方式は .env の COMPOSE_PROFILES で選ぶ（tunnel / caddy / 空=背後配置）。
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose -f compose.yaml -f compose.prod.yaml up -d --build
docker compose -f compose.yaml -f compose.prod.yaml ps
