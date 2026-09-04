#!/usr/bin/env bash
# コンテナの中に入る。
#
#   bin/shell.sh              # ec-cube に www-data で入る（既定）
#   bin/shell.sh --root       # ec-cube に root で入る
#   bin/shell.sh db           # 他のサービスに入る
#   bin/shell.sh db --root
#
# **既定を www-data にしてある。** root のまま bin/console や composer を打つと
# var/cache と var/log に root 所有のファイルができ、そのあと php-fpm（www-data）が
# 書けなくなって**全ページ 500** になる。root が要るのはパッケージの導入や
# php-fpm への USR2 送信など限られた場面だけ。
set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/stack.sh"

as_root=0
service=""

for a in "$@"; do
    case "$a" in
        --root) as_root=1 ;;
        -*) echo "不明な指定: $a" >&2; exit 1 ;;
        *) service="$a" ;;
    esac
done

service="${service:-ec-cube}"

# **シェルはイメージによって違う。** nginx と redis は alpine なので bash が無い。
shell=bash
case "$service" in
    nginx|redis|redis-session|mailpit) shell=sh ;;
esac

user=()
# **www-data がいないイメージがある。** db や redis に -u www-data を渡すと
# 「unable to find user」で入れない。ec-cube と worker だけに付ける。
if [ "$as_root" = "0" ]; then
    case "$service" in
        ec-cube|worker) user=(-u www-data) ;;
    esac
fi

# 止まっていると exec は通らない。**まず「本当に止まっているのか、別のスタックを
# 見ているのか」を切り分ける。** 名前がずれているだけなら、使い捨てのコンテナで
# 入っても意味がない（DB も別なので中身が違う）。
if ! stack_require_running "$service" shell; then
    echo >&2
    echo "[shell] このまま使い捨てのコンテナで入ります（中身は空の状態です）。" >&2
    echo "[shell] 上の案内で目的のスタックが分かるなら、Ctrl-C で中止してください。" >&2
    exec docker compose run --rm --no-deps ${user[@]+"${user[@]}"} "$service" "$shell"
fi

exec docker compose exec ${user[@]+"${user[@]}"} "$service" "$shell"
