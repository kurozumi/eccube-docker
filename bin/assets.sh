#!/usr/bin/env bash
# フロント CSS/JS のビルド補助。
#
#   独自テーマ方式（推奨・本体非編集）:
#     bin/assets.sh build        frontend/scss → html/user_data/assets/css/customize.css を一括ビルド
#     bin/assets.sh watch        上記を監視ビルド（node サービスのログを追う）
#
#   純正ツールチェーン（本体テーマを丸ごと作り替えるとき / Git 管理外）:
#     bin/assets.sh core-build   本体の npm ci && npm run build（Gulp/Webpack）
#
# 独自テーマの customize.css / customize.js は本体 default_frame.twig が自動読込するため
# 上書き Twig は不要。編集後はブラウザをリロードすれば反映される。
set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-help}"
case "$cmd" in
  build)
    docker compose run --rm node sh -lc "npm install --no-audit --no-fund && npm run build"
    ;;
  watch)
    docker compose up -d node
    echo "watch 起動。停止は Ctrl-C（サービスは動き続ける。止めるなら docker compose stop node）"
    docker compose logs -f node
    ;;
  core-build)
    docker compose --profile assets-core run --rm assets-core "npm ci && npm run build"
    ;;
  core-watch)
    # 本体 npm start は browser-sync が 127.0.0.1:8080 を前提とするためコンテナ内では
    # ライブリロードが効かない。ビルドは走る。通常は core-build を使うこと。
    docker compose --profile assets-core run --rm assets-core "npm ci && npm start"
    ;;
  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
