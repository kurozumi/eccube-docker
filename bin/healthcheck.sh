#!/usr/bin/env bash
# フロントが応答するか簡易チェック。
set -euo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."

# shellcheck source=lib/compose.sh
. bin/lib/compose.sh
url="$(compose_nginx_url)/"   # HTTP_BIND で内側の IP だけに開いていても、実際に開いている場所を見る

code="$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)"
echo "GET ${url} -> ${code}"
case "$code" in
    200 | 301 | 302) echo "OK"; exit 0 ;;
    *) echo "NG"; exit 1 ;;
esac
