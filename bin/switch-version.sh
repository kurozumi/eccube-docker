#!/usr/bin/env bash
# EC-CUBE のバージョンを切り替える。スキーマが変わるため DB とアプリのボリュームを作り直す。
#   使い方: bin/switch-version.sh ~4.2.0
#           bin/switch-version.sh 4.4.x-dev --php=8.5   PHP も選ぶ（系列が対応している版だけ）
#
# これは「指定バージョンをまっさらに立て直す」開発用ツールで、バージョンアップ用ではない。
# 運用中の環境をデータを保ったまま上げるには bin/upgrade.sh を使うこと。
#
# 破棄は必ずビルドが通ってから行う。先に down -v するとビルド失敗時にデータだけ消えて
# 環境が残らない（新バージョンの取得は composer 依存解決に失敗しうる）。
set -euo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

ver=""; want_php=""
for a in "$@"; do
    case "$a" in
        --php=*) want_php="${a#--php=}" ;;
        --php)   echo "エラー: --php=8.3 の形で指定してください。" >&2; exit 1 ;;
        *)       [ -z "$ver" ] && ver="$a" ;;
    esac
done
if [ -z "$ver" ]; then
    echo "使い方: bin/switch-version.sh <制約> [--php=<版>]   例: ~4.3.0 / ~4.2.0 / 4.4.x-dev --php=8.5"
    exit 1
fi

image_check_version "$ver" "bin/switch-version.sh" || exit 1
# PHP は**何かを消す前に**決める。使えない組み合わせなら、ここで止まれば何も失わない。
# 作り直すので「いまの PHP」は .env の値（配布イメージならタグ）でよい。
current_php="$(grep -E '^PHP_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
had_php_key=0; grep -qE '^PHP_VERSION=' .env 2>/dev/null && had_php_key=1
# 実物を先に見る（-php 無しの固定タグはタグから PHP が分からない。upgrade.sh と同じ）
cid_now="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"
base_php=""
[ -n "$cid_now" ] && base_php="$(image_php_of_container "$cid_now")"
if [ -z "$base_php" ]; then
    if image_uses_registry; then
        base_php="$(image_ref_php "$(env_get ECCUBE_IMAGE)")"
    else
        base_php="$current_php"
    fi
fi
php_ver="$(image_resolve_php "$(image_series "$ver")" "$want_php" "$base_php")" || exit 1
echo "[switch] ECCUBE_VERSION=${ver} に切り替えます。既存の DB とアプリのデータは破棄されます。"
echo "[switch] 注意: アップロード画像（eccube_upload）も削除されます。残したい場合は先にバックアップを:"
echo "         docker compose cp ec-cube:/var/www/html/html/upload/. ./upload-backup/"
echo "         （NFS/EFS ドライバで運用していれば外部データは消えません）"
guard_destructive switch-version.sh "DB・アップロード画像・セッション"

current="$(grep -E '^ECCUBE_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
current_redis="$(grep -E '^PHPREDIS_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"

current_image="$(env_get ECCUBE_IMAGE)"

# phpredis は EC-CUBE 側の Symfony Cache に合わせる必要があり、両立しない。
# 対応表は bin/lib/image.sh に集約してある（CI の matrix と揃える先もそこ）。
series="$(image_series "$ver")"
redis_ver="$(image_phpredis_for_series "$series")"
echo "[switch] phpredis は ${redis_ver} を使用します（EC-CUBE ${ver} 向け）。"
echo "[switch] PHP は ${php_ver} を使用します。"
if grep -qE '^PHP_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^PHP_VERSION=.*|PHP_VERSION=${php_ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "PHP_VERSION=${php_ver}" >> .env
fi

if grep -qE '^PHPREDIS_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^PHPREDIS_VERSION=.*|PHPREDIS_VERSION=${redis_ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "PHPREDIS_VERSION=${redis_ver}" >> .env
fi

if grep -qE '^ECCUBE_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^ECCUBE_VERSION=.*|ECCUBE_VERSION=${ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "ECCUBE_VERSION=${ver}" >> .env
fi

# 配布イメージを使っているなら、タグの系列も一緒に動かす。
# **ここを忘れると、.env だけ 4.4 になって動くのは 4.3 のイメージ**という
# 食い違いになる（build しないので ECCUBE_VERSION は参照されない）。
if [ -n "$current_image" ]; then
    retagged="$(image_retag_php "$(image_retag_series "$current_image" "$series")" "$php_ver")"
    if [ "$retagged" != "$current_image" ]; then
        tmp="$(mktemp)"
        sed "s|^ECCUBE_IMAGE=.*|ECCUBE_IMAGE=${retagged}|" .env > "$tmp" && mv "$tmp" .env
        echo "[switch] ECCUBE_IMAGE を ${retagged} に合わせました。"
    elif image_uses_registry; then
        echo "[switch] 注意: ECCUBE_IMAGE=${current_image} は系列を含まないタグです。"
        echo "         このタグが ${series} 系のものか、自分で確かめてください。"
    fi
fi

# 先にイメージを用意する。ここで落ちても既存の環境とデータは無傷なので、
# .env だけ戻して終わる。
if ! image_provision docker compose; then
    echo "[switch] エラー: イメージを用意できませんでした。既存の環境とデータはそのままです。" >&2
    if [ -n "$current" ]; then
        tmp="$(mktemp)"
        sed "s|^ECCUBE_VERSION=.*|ECCUBE_VERSION=${current}|" .env > "$tmp" && mv "$tmp" .env
        echo "[switch] .env の ECCUBE_VERSION を ${current} へ戻しました。" >&2
    fi
    if [ -n "$current_redis" ]; then
        tmp="$(mktemp)"
        sed "s|^PHPREDIS_VERSION=.*|PHPREDIS_VERSION=${current_redis}|" .env > "$tmp" && mv "$tmp" .env
    fi
    if [ -n "$current_image" ]; then
        tmp="$(mktemp)"
        sed "s|^ECCUBE_IMAGE=.*|ECCUBE_IMAGE=${current_image}|" .env > "$tmp" && mv "$tmp" .env
    fi
    if [ "$had_php_key" = 0 ]; then
        tmp="$(mktemp)"
        grep -vE '^PHP_VERSION=' .env > "$tmp" || true
        mv "$tmp" .env
    else
        tmp="$(mktemp)"
        sed "s|^PHP_VERSION=.*|PHP_VERSION=${current_php}|" .env > "$tmp" && mv "$tmp" .env
    fi
    exit 1
fi

# ビルドが通ってから破棄する。
docker compose down -v
docker compose up -d
echo "[switch] 完了。進捗: docker compose logs -f ec-cube"
