#!/usr/bin/env bash
# 初回セットアップ: .env 作成 → シークレット生成 → ビルド＆起動。
set -euo pipefail
cd "$(dirname "$0")/.."

fresh_env=0
if [ ! -f .env ]; then
    cp .env.example .env
    fresh_env=1
    echo "[init] .env を作成しました"
fi

# .env の値を置き換えるヘルパー
set_env() { # set_env KEY VALUE
    tmp="$(mktemp)"
    sed "s|^${1}=.*|${1}=${2}|" .env > "$tmp" && mv "$tmp" .env
}

# ECCUBE_AUTH_MAGIC が未設定/プレースホルダなら生成する
current="$(grep -E '^ECCUBE_AUTH_MAGIC=' .env | head -1 | cut -d= -f2- || true)"
case "$current" in
    "" | change_this_to_a_random_hex_string)
        set_env ECCUBE_AUTH_MAGIC "$(openssl rand -hex 16)"
        echo "[init] ECCUBE_AUTH_MAGIC を生成しました"
        ;;
esac

# DB パスワード類は「.env を新規作成したときだけ」自動生成する。
# 既存 .env の場合、DB は古いパスワードで初期化済みのため書き換えると接続不能になる。
if [ "$fresh_env" = "1" ]; then
    set_env DB_PASSWORD "$(openssl rand -hex 16)"
    set_env DB_ROOT_PASSWORD "$(openssl rand -hex 16)"
    echo "[init] DB_PASSWORD / DB_ROOT_PASSWORD を生成しました"
else
    for pair in "DB_PASSWORD=eccube_pass" "DB_ROOT_PASSWORD=change_me_root"; do
        if grep -qE "^${pair}$" .env 2>/dev/null; then
            echo "[init] 警告: ${pair%%=*} が既定値のままです。DB 初期化前なら変更を推奨。"
            echo "        （DB 初期化済みで変えるなら docker compose down -v でデータごと作り直し）"
        fi
    done
fi

echo "[init] ビルドして起動します（初回は EC-CUBE 取得で数分かかります）..."
docker compose up -d --build

echo "[init] 進捗確認: docker compose logs -f ec-cube"
echo "[init] フロント: http://localhost:${HTTP_PORT:-8080}/   管理: http://localhost:${HTTP_PORT:-8080}/admin/"
