#!/usr/bin/env bash
# DB を初期状態へ戻す（ボリュームを破棄して再構築・再インストール）。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

guard_destructive reset.sh "DB・アップロード画像・セッション"

# 先にイメージを用意する（配布イメージなら pull、なければ build）。
# `up -d --build` と書くと、配布イメージを使っている利用者の環境で pull した
# イメージをローカル build で潰す。他の起動系スクリプトと同じ扱いにする。
if ! image_provision docker compose; then
    echo "[reset] エラー: イメージを用意できませんでした。何も消していません。" >&2
    exit 1
fi

docker compose down -v
docker compose up -d
echo "[reset] 完了。進捗: docker compose logs -f ec-cube"
