#!/usr/bin/env bash
# EC-CUBE を「データを保ったまま」新しいバージョンへ上げる。
#   使い方: bin/upgrade.sh ~4.3.2
#
# bin/switch-version.sh との違い:
#   switch-version.sh … down -v で DB・画像ごと破棄して作り直す（開発で別バージョンを試す用）
#   upgrade.sh        … DB(db_data) と画像(eccube_upload) は残し、本体コードだけ差し替えて
#                       未適用 migration を適用する（運用中の環境を上げる用）
#
# 仕組み（重要）:
#   eccube_app ボリュームが /var/www/html 全体を覆っているため、イメージを作り直しても
#   既存ボリュームが残っている限り新しい本体コードは反映されない（docker/php/
#   docker-entrypoint.sh の 1b) のコメント参照）。そこで eccube_app *だけ* 作り直し、
#   db_data と eccube_upload はそのまま残す。
#   ただし作り直した直後は var/.eccube_installed が消えるため、entrypoint が
#   「未インストール」と誤判定して既存 DB に eccube:install を撃ってしまう。
#   これを避けるため、起動前にマーカーだけ先に置いて migration 経路へ寄せる。
#   さらに、スキーマ（DDL）とデータ移行は別経路なので両方を流す（詳細は下の 7)）。
set -euo pipefail
cd "$(dirname "$0")/.."

ver="${1:-}"
if [ -z "$ver" ]; then
    echo "使い方: bin/upgrade.sh <制約>   例: ~4.3.2"
    echo "  データを保ったままバージョンを上げます。"
    echo "  データごと作り直したい場合は bin/switch-version.sh を使ってください。"
    exit 1
fi

current="$(grep -E '^ECCUBE_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"

# compose のプロジェクト名（ボリューム名の接頭辞）。COMPOSE_PROJECT_NAME や
# compose.yaml の name: を compose 自身に解決させる。
proj="$(docker compose config --format json | sed -n 's/^  "name": "\(.*\)",$/\1/p' | head -1)"
if [ -z "$proj" ]; then
    echo "エラー: compose のプロジェクト名を取得できませんでした。" >&2
    exit 1
fi
app_vol="${proj}_eccube_app"
db_vol="${proj}_db_data"

# DB ボリュームが無い＝まだ 1 度も構築していない。upgrade ではなく init の出番。
if ! docker volume inspect "$db_vol" >/dev/null 2>&1; then
    echo "エラー: DB ボリューム（${db_vol}）がありません。まだ構築されていない環境です。" >&2
    echo "       初回セットアップは bin/init.sh を使ってください。" >&2
    exit 1
fi

cat <<EOS
[upgrade] EC-CUBE をバージョンアップします。
          現在: ${current:-(未設定)}
          変更後: ${ver}

  残るもの : DB(${db_vol}) / アップロード画像(${proj}_eccube_upload)
             app/Customize・app/template・app/Plugin など bind-mount 一式
  作り直し : 本体コード(${app_vol})。var/ 以下のログとキャッシュも消えます。

  注意:
   - スキーマは doctrine:migrations:migrate で前進します。ダウングレードはできません。
     元に戻すには .env を戻して再実行し、bin/restore.sh で DB を書き戻す必要があります。
   - マイナー/メジャーをまたぐ場合、既存プラグインが新バージョン非対応だと起動後に
     エラーになることがあります。事前に対応状況を確認してください。
EOS
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

# 1) 先にバックアップ。ここで失敗したら何も壊さずに終わる。
echo "[upgrade] バックアップを取得します..."
if ! bin/backup.sh; then
    echo "[upgrade] エラー: バックアップに失敗しました。中止します。" >&2
    exit 1
fi
backup_dir="$(ls -1d backups/*/ 2>/dev/null | sort | tail -1 || true)"
echo "[upgrade] バックアップ: ${backup_dir:-(不明)}"

# 2) .env を更新。以降の失敗時は元の値へ戻す。
restore_env() {
    if [ -n "$current" ]; then
        tmp="$(mktemp)"
        sed "s|^ECCUBE_VERSION=.*|ECCUBE_VERSION=${current}|" .env > "$tmp" && mv "$tmp" .env
        echo "[upgrade] .env の ECCUBE_VERSION を ${current} へ戻しました。" >&2
    fi
}
if grep -qE '^ECCUBE_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^ECCUBE_VERSION=.*|ECCUBE_VERSION=${ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "ECCUBE_VERSION=${ver}" >> .env
fi

# 3) 新バージョンのイメージを先に作る。ここで落ちても稼働中の環境は無傷。
echo "[upgrade] イメージをビルドします（EC-CUBE 取得で数分かかります）..."
if ! docker compose build; then
    echo "[upgrade] エラー: ビルドに失敗しました。稼働中の環境はそのままです。" >&2
    restore_env
    exit 1
fi

# 4) 停止（-v は付けない = DB と画像は残る）→ 本体ボリュームだけ破棄
echo "[upgrade] コンテナを停止します（ボリュームは残します）..."
docker compose down

echo "[upgrade] 本体ボリューム ${app_vol} を作り直します..."
docker volume rm "$app_vol" >/dev/null 2>&1 || true

# 5) 起動前にマーカーを置く。
#    ここで eccube_app が新イメージの内容で作られ、同時に .eccube_installed を置くことで
#    entrypoint の eccube:install 分岐（既存 DB を壊す）を回避して migration 経路に入る。
echo "[upgrade] インストール済みマーカーを設定します..."
docker compose run --rm --no-deps --entrypoint sh ec-cube \
    -c 'mkdir -p /var/www/html/var && touch /var/www/html/var/.eccube_installed'

# 6) 起動。entrypoint が独自 migration（app/DoctrineMigrations）を適用する。
echo "[upgrade] 起動します..."
docker compose up -d

# 7) スキーマとデータを追従させる。EC-CUBE 4.x のバージョンアップは 2 段構え。
#
#    DDL  : 本体の migration に ALTER/CREATE TABLE は 1 件も無く、スキーマの正は
#           エンティティ定義。よって doctrine:schema:update で DB を定義へ合わせる。
#           これを飛ばすと新しいエンティティが期待するカラムが無くて全ページ 500 に
#           なる（4.2 -> 4.3 なら dtb_base_info.ga_id）。
#           --complete は付けない。付けると「定義に無い列」を削除するため、
#           プラグインが追加した列を巻き添えで落とす。
#    データ: 本体の migration（app/DoctrineMigrations の 18 件）はすべてデータ移行
#           （マスタ追加・不整合の是正など）。doctrine:migrations:migrate で流す。
#           カラムが揃ってから流したいので schema:update の後に実行する。
#           各 migration は存在チェックで保護されているので再実行は安全。
echo "[upgrade] コンテナの準備を待っています..."
for i in $(seq 1 60); do
    docker compose exec -T ec-cube php -v >/dev/null 2>&1 && break
    sleep 5
done

echo "[upgrade] 本体スキーマの差分:"
docker compose exec -T ec-cube runuser -u www-data -- \
    php bin/console doctrine:schema:update --dump-sql 2>&1 | sed 's/^/    /' || true

echo "[upgrade] スキーマを更新します..."
if ! docker compose exec -T ec-cube runuser -u www-data -- \
        php bin/console doctrine:schema:update --force; then
    cat <<EOS >&2
[upgrade] エラー: スキーマ更新に失敗しました。
  ログ: docker compose logs ec-cube
  切り戻し: bin/upgrade.sh ${current:-元の値} のあと bin/restore.sh ${backup_dir:-backups/<日時>}
EOS
    exit 1
fi

echo "[upgrade] データ移行（migration）を適用します..."
if ! docker compose exec -T ec-cube runuser -u www-data -- \
        php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration; then
    cat <<EOS >&2
[upgrade] エラー: migration の適用に失敗しました。
  ログ: docker compose logs ec-cube
  切り戻し: bin/upgrade.sh ${current:-元の値} のあと bin/restore.sh ${backup_dir:-backups/<日時>}
EOS
    exit 1
fi

docker compose exec -T ec-cube runuser -u www-data -- \
    php bin/console cache:clear --no-interaction >/dev/null 2>&1 || true

# 8) 応答するまで待つ
echo "[upgrade] 起動を待っています..."
for i in $(seq 1 60); do
    if bin/healthcheck.sh >/dev/null 2>&1; then
        echo "[upgrade] 完了。${current:-?} -> ${ver} へ更新しました。"
        bin/healthcheck.sh
        echo "[upgrade] 管理画面とフロントの表示、受注データを必ず目視で確認してください。"
        exit 0
    fi
    sleep 5
done

cat <<EOS >&2

[upgrade] エラー: 起動を確認できませんでした。
  ログ: docker compose logs ec-cube
  切り戻し:
    1) .env の ECCUBE_VERSION を ${current:-元の値} に戻す
    2) bin/upgrade.sh ${current:-元の値}   （本体コードを戻す）
    3) 必要なら bin/restore.sh ${backup_dir:-backups/<日時>}   （DB を書き戻す）
EOS
exit 1
