#!/usr/bin/env bash
# EC-CUBE のバージョンを切り替える。スキーマが変わるため DB とアプリのボリュームを作り直す。
#   使い方: bin/switch-version.sh ~4.2.0
#
# これは「指定バージョンをまっさらに立て直す」開発用ツールで、バージョンアップ用ではない。
# 運用中の環境をデータを保ったまま上げるには bin/upgrade.sh を使うこと。
#
# 破棄は必ずビルドが通ってから行う。先に down -v するとビルド失敗時にデータだけ消えて
# 環境が残らない（新バージョンの取得は composer 依存解決に失敗しうる）。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

ver="${1:-}"
if [ -z "$ver" ]; then
    echo "使い方: bin/switch-version.sh <制約>   例: ~4.3.0 / ~4.2.0 / ~4.1.0"
    exit 1
fi

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
    retagged="$(image_retag_series "$current_image" "$series")"
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
    exit 1
fi

# ビルドが通ってから破棄する。
docker compose down -v
docker compose up -d
echo "[switch] 完了。進捗: docker compose logs -f ec-cube"
