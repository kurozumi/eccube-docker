#!/usr/bin/env bash
# 初回セットアップ: .env 作成 → シークレット生成 → ビルド＆起動。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

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

# DB_ENGINE に合わせて compose ファイルの並びを .env に固定する。
# PostgreSQL は compose.postgresql.yaml を重ねる必要があり、それを COMPOSE_FILE に持たせて
# おけば、素の `docker compose` も bin/*.sh も同じ並びで動く（bin/lib/compose.sh 参照）。
engine="$(grep -E '^DB_ENGINE=' .env | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
case "${engine:-mysql}" in
    postgresql) files="compose.yaml:compose.override.yaml:compose.postgresql.yaml" ;;
    mysql|"")   files="compose.yaml:compose.override.yaml" ;;
    *) echo "[init] エラー: DB_ENGINE は mysql か postgresql です（いま: ${engine}）" >&2; exit 1 ;;
esac
if grep -qE '^COMPOSE_FILE=' .env; then
    set_env COMPOSE_FILE "$files"
else
    printf '\n# compose ファイルの並び（bin/init.sh が DB_ENGINE から組み立てた。手で -f を並べない）\nCOMPOSE_FILE=%s\n' "$files" >> .env
fi
echo "[init] DB: ${engine:-mysql}（COMPOSE_FILE=${files}）"

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

# 配布イメージ（ECCUBE_IMAGE）を使うなら pull、そうでなければ build。
# **ここで `up -d --build` と書かない。** 配布イメージを指定している利用者の
# 環境では、pull したイメージをローカル build で上書きしてしまう。
if ! image_provision docker compose; then
    echo "[init] エラー: イメージを用意できませんでした。" >&2
    exit 1
fi

echo "[init] 起動します..."
docker compose up -d

echo "[init] 進捗確認: docker compose logs -f ec-cube"
echo "[init] フロント: http://localhost:${HTTP_PORT:-8080}/   管理: http://localhost:${HTTP_PORT:-8080}/admin/"
