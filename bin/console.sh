#!/usr/bin/env bash
# bin/console をコンテナの中で実行する。
#
#   bin/console.sh debug:router
#   bin/console.sh doctrine:migrations:generate
#   bin/console.sh dbal:run-sql "SELECT COUNT(*) FROM dtb_order"
#
# **www-data で実行する。** root で走らせると var/cache と var/log に root 所有の
# ファイルができ、そのあと php-fpm（www-data）が書けなくなって**全ページ 500** になる。
# 手で打つと付け忘れるのでここで固定する。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then
    set -- list
fi

# **独自 migration は必ず CustomizeMigrations 名前空間へ。**
# 付けないと本体側（イメージの中の app/DoctrineMigrations）に作られる。
# ホストには現れず、次のビルドで消える。その場では動くので気づきにくい。
case "${1:-}" in
    doctrine:migrations:generate|doctrine:migrations:diff)
        has_ns=0
        for a in "$@"; do
            case "$a" in --namespace|--namespace=*) has_ns=1 ;; esac
        done

        if [ "$has_ns" = "0" ]; then
            echo "[console] --namespace=CustomizeMigrations を補いました（独自 migration の置き場所）。" >&2
            set -- "$@" --namespace=CustomizeMigrations
        fi
        ;;
esac

exec docker compose exec ec-cube runuser -u www-data -- php bin/console "$@"
