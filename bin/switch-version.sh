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

ver="${1:-}"
if [ -z "$ver" ]; then
    echo "使い方: bin/switch-version.sh <制約>   例: ~4.3.0 / ~4.2.0 / ~4.1.0"
    exit 1
fi

echo "[switch] ECCUBE_VERSION=${ver} に切り替えます。既存の DB とアプリのデータは破棄されます。"
echo "[switch] 注意: アップロード画像（eccube_upload）も削除されます。残したい場合は先にバックアップを:"
echo "         docker compose cp ec-cube:/var/www/html/html/upload/. ./upload-backup/"
echo "         （NFS/EFS ドライバで運用していれば外部データは消えません）"
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

current="$(grep -E '^ECCUBE_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
current_redis="$(grep -E '^PHPREDIS_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"

# phpredis は EC-CUBE 側の Symfony Cache に合わせる必要があり、両立しない。
#   4.2 / 4.3（Symfony Cache 6.4） … 6.0.x（6.1+ は hSet のシグネチャ変更で衝突）
#   4.4（Symfony Cache 7.4）       … 6.1 以上（symfony/cache が ext-redis <6.1 を conflict）
case "$ver" in
    4.4*|~4.4*|^4.4*) redis_ver="6.3.0" ;;
    *)                redis_ver="6.0.2" ;;
esac
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

# 先にビルドする。ここで落ちても既存の環境とデータは無傷なので、.env だけ戻して終わる。
echo "[switch] イメージをビルドします（EC-CUBE 取得で数分かかります）..."
if ! docker compose build; then
    echo "[switch] エラー: ビルドに失敗しました。既存の環境とデータはそのままです。" >&2
    if [ -n "$current" ]; then
        tmp="$(mktemp)"
        sed "s|^ECCUBE_VERSION=.*|ECCUBE_VERSION=${current}|" .env > "$tmp" && mv "$tmp" .env
        echo "[switch] .env の ECCUBE_VERSION を ${current} へ戻しました。" >&2
    fi
    if [ -n "$current_redis" ]; then
        tmp="$(mktemp)"
        sed "s|^PHPREDIS_VERSION=.*|PHPREDIS_VERSION=${current_redis}|" .env > "$tmp" && mv "$tmp" .env
    fi
    exit 1
fi

# ビルドが通ってから破棄する。
docker compose down -v
docker compose up -d
echo "[switch] 完了。進捗: docker compose logs -f ec-cube"
