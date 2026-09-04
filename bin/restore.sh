#!/usr/bin/env bash
# バックアップ（bin/backup.sh の出力）から復元する。
#   使い方:  bin/restore.sh backups/20260721-040000
#
# 戻すもの:
#   db.sql.gz          DB（既存データを DROP して置き換える。確認プロンプトあり）
#   upload.tar.gz      アップロード画像
#   admin-files.tar.gz 管理画面が書いたファイル（app/template・customize.css/js）
#   container.env      **戻さない。** 管理画面が書くキーの差分を出すだけ。
#                      ホストの .env や compose が渡す値と衝突しうるので、人が決める。
#
# 引っ越しは「clone → bin/init.sh → bin/restore.sh <退避先>」で完結する。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"

# ボリュームは alpine で触る（bin/backup.sh と同じ理由: ec-cube のイメージが
# 無いとフルビルドが始まる）。
proj="$(guard_project_name)"
[ -n "$proj" ] || { echo "[restore] エラー: compose のプロジェクト名を取得できません" >&2; exit 1; }
vol_rw() { # vol_rw <ボリューム名> <マウント先> <コマンド…>
    docker run --rm -i -v "${proj}_$1:$2" alpine:3 "${@:3}"
}

src="${1:-}"
if [ -z "$src" ] || [ ! -f "${src}/db.sql.gz" ]; then
    echo "使い方: bin/restore.sh <バックアップディレクトリ>"
    echo "  例: bin/restore.sh backups/20260721-040000"
    ls -1d backups/*/ 2>/dev/null | sed 's/^/  候補: /' || true
    exit 1
fi

echo "[restore] ${src} から復元します。現在の DB は上書きされます。"
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

echo "[restore] DB を復元しています..."
gunzip -c "${src}/db.sql.gz" | docker compose exec -T db sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root "$MYSQL_DATABASE"'

if [ -f "${src}/upload.tar.gz" ]; then
    echo "[restore] アップロード画像を復元しています..."
    # 書庫の先頭は upload/ なので、/ に展開すると /upload（＝ボリューム）に重なる。
    # www-data は uid 33（php:*-fpm 系の既定）。alpine には無いので数字で指定する。
    vol_rw eccube_upload /upload sh -c 'tar -C / -xzf - && chown -R 33:33 /upload' < "${src}/upload.tar.gz"
fi

if [ -f "${src}/admin-files.tar.gz" ]; then
    # ホスト側へ展開する（bind mount なのでコンテナからも見える）。
    # 中身は app/template と customize.css/js。git 管理下のパスを上書きするので、
    # 引っ越し先で git が汚れて見えるのは正常（本番で管理画面が書いた分）。
    echo "[restore] 管理画面が書いたファイルを復元しています..."
    tar -xzf "${src}/admin-files.tar.gz"
fi

if [ -f "${src}/container.env" ]; then
    # 管理画面がコンテナ内 .env に書くキーだけを比べる。
    # 自動で書き戻さない。ECCUBE_ADMIN_ROUTE のように compose が環境変数で渡して
    # いるキーは、書き戻しても効かない（環境変数が勝つ）うえ、本体はその状態を
    # 「上書きされている」と警告する。
    cur="$(docker run --rm -v "${proj}_eccube_app:/app:ro" alpine:3 cat /app/.env 2>/dev/null || true)"
    diffs=""
    for k in ECCUBE_TEMPLATE_CODE ECCUBE_FRONT_ALLOW_HOSTS ECCUBE_FRONT_DENY_HOSTS \
             ECCUBE_ADMIN_ALLOW_HOSTS ECCUBE_ADMIN_DENY_HOSTS ECCUBE_FORCE_SSL TRUSTED_HOSTS; do
        was="$(grep -E "^${k}=" "${src}/container.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        now="$(printf '%s\n' "$cur" | grep -E "^${k}=" | head -1 | cut -d= -f2- || true)"
        if [ -n "$was" ] && [ "$was" != "$now" ]; then
            diffs="${diffs}    ${k}=${was}   （いま: ${now:-未設定}）\n"
        fi
    done
    if [ -n "$diffs" ]; then
        echo "[restore] 注意: 管理画面がコンテナ内 .env に書いていた値が、いまの環境と違います:"
        printf '%b' "$diffs"
        echo "           必要なら .env（ホスト）に書いて docker compose up -d してください。"
        echo "           テーマ（ECCUBE_TEMPLATE_CODE）は .env に書くのが正です（管理画面の選択は upgrade で消えます）。"
    fi
fi

echo "[restore] キャッシュをクリアしています..."
docker compose exec -T ec-cube runuser -u www-data -- php bin/console cache:clear --no-interaction >/dev/null 2>&1 || true

echo "[restore] 完了。bin/healthcheck.sh で動作確認してください。"
