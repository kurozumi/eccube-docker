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

# ec-cube サービスのイメージ名（事前確認で compose を介さず直接起動するのに使う）。
# `config --images ec-cube` はサービス指定を無視して全イメージを返すので使わない。
image="$(docker compose config 2>/dev/null |
    awk '/^  ec-cube:$/{b=1;next} b&&/^  [a-zA-Z_-]+:$/{b=0} b&&/^    image:/{sub(/^    image: */,"");print;exit}')"
if [ -z "$image" ]; then
    echo "エラー: ec-cube のイメージ名を取得できませんでした。" >&2
    exit 1
fi

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

# 3b) 新バージョンでプラグインと独自コードが読めるか、稼働中の環境に触る前に確かめる。
#     プラグインが新バージョン非対応だとクラス宣言の互換性チェックで Fatal error に
#     なり、あらゆる console コマンドが死ぬ。例（4.2 世代のプラグインを 4.3 に載せた場合）:
#
#       Fatal error: Declaration of Plugin\Foo\PluginManager::install(...
#       must be compatible with Eccube\Plugin\AbstractPluginManager::install(...
#
#     down してから気づくと切り戻しに時間がかかるので、ここで落として稼働中の環境を守る。
#     eccube_app ボリュームを渡さないので、新イメージの本体コードがそのまま使われる。
echo "[upgrade] 新バージョンでプラグインが読めるか確認します..."
preflight="$(docker run --rm \
    -v "$PWD/app/Plugin:/var/www/html/app/Plugin:ro" \
    -v "$PWD/app/Customize:/var/www/html/app/Customize:ro" \
    --entrypoint sh "$image" -c 'php bin/console list 2>&1' 2>&1 || true)"
if printf '%s' "$preflight" | grep -q 'Fatal error'; then
    echo "[upgrade] エラー: 新バージョンでコードを読み込めません。中止します。" >&2
    echo "[upgrade] 稼働中の環境・DB・画像には一切触れていません。" >&2
    echo >&2
    printf '%s\n' "$preflight" | grep -v '^Deprecated:' | grep 'Fatal error' | head -3 >&2
    echo >&2
    echo "[upgrade] 該当プラグインを新バージョン対応版へ更新するか、無効化・削除してから" >&2
    echo "          再実行してください（app/Plugin から外すだけでも確認できます）。" >&2
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

# 6) 公開する前にスキーマとデータを合わせる。
#
#    ここで先に up -d してしまうと、新コード + 旧スキーマの状態で nginx が公開され、
#    スキーマ更新が終わるまで全ページ 500 を返す。そこで nginx を上げずに、db だけを
#    連れてくる使い捨てコンテナ（compose run）で先に整合させてから公開する。
#    ec-cube の depends_on は db / redis / redis-session なので、compose run では
#    nginx と worker は起動しない。
#
#    ECCUBE_SKIP_DB_INIT=1 / ECCUBE_SKIP_CACHE_CLEAR=1:
#    entrypoint には環境準備（app/config のマージ等）だけさせ、install や migrate は
#    撃たせない。適用順はこのスクリプトが制御する。
#
#    EC-CUBE 4.x のバージョンアップは 2 段構え:
#    DDL  : 本体の migration に ALTER/CREATE TABLE は 1 件も無く、スキーマの正は
#           エンティティ定義。よって doctrine:schema:update で DB を定義へ合わせる。
#           これを飛ばすと新しいエンティティが期待するカラムが無くて全ページ 500 に
#           なる（4.2 -> 4.3 なら dtb_base_info.ga_id）。
#           注意: schema:update は --complete の有無にかかわらず「エンティティ定義に
#           無い列」を削除する（--complete 無しで残るのはテーブルだけ）。よって
#           proxy を先に生成してプラグインの拡張をメタデータに載せ、そのうえで
#           差分に削除が混じっていないか確認してから --force する。
#    データ: 本体の migration（app/DoctrineMigrations の 18 件）はすべてデータ移行
#           （マスタ追加・不整合の是正など）。doctrine:migrations:migrate で流す。
#           カラムが揃ってから流したいので schema:update の後に実行する。
#           各 migration は存在チェックで保護されているので再実行は安全。
offline() { # offline <表示名> <console の引数...>
    local label="$1"; shift
    if ! docker compose run --rm \
            -e ECCUBE_SKIP_DB_INIT=1 -e ECCUBE_SKIP_CACHE_CLEAR=1 \
            ec-cube runuser -u www-data -- php bin/console "$@"; then
        cat <<EOS >&2
[upgrade] エラー: ${label}に失敗しました。サイトはまだ公開していません。
  ログ: docker compose logs ec-cube
  切り戻し: bin/upgrade.sh ${current:-元の値} のあと bin/restore.sh ${backup_dir:-backups/<日時>}
EOS
        exit 1
    fi
}

# エンティティ proxy を先に作り直す。eccube_app を作り直すと app/proxy/entity が
# 消えるため、これを飛ばすと「有効なプラグインのエンティティ拡張」がメタデータに
# 載らない。schema:update は *エンティティ定義に無い列を削除する* ので、そのまま
# 流すとプラグインが追加した列（例: EntityExtension の dtb_customer.sort_no）を
# データごと落とす。
echo "[upgrade] エンティティ proxy を生成します..."
offline "proxy の生成" eccube:generate:proxies

echo "[upgrade] 本体スキーマの差分:"
diff_sql="$(docker compose run --rm -e ECCUBE_SKIP_DB_INIT=1 -e ECCUBE_SKIP_CACHE_CLEAR=1 \
    ec-cube runuser -u www-data -- php bin/console doctrine:schema:update --dump-sql 2>&1 || true)"
printf '%s\n' "$diff_sql" | sed 's/^/    /'

# 列やテーブルの削除が混じっていないか確かめる。
# DROP INDEX / DROP FOREIGN KEY / DROP PRIMARY KEY は索引の貼り直しで普通に出るので
# 除外し、それ以外の DROP（＝列・テーブルの削除）だけを危険と見なす。
risky="$(printf '%s' "$diff_sql" |
    sed -E 's/DROP (INDEX|FOREIGN KEY|PRIMARY KEY)[^,;]*//gi' |
    grep -iE 'DROP ' || true)"
if [ -n "$risky" ] && [ "${UPGRADE_ALLOW_DROP:-0}" != "1" ]; then
    cat <<EOS >&2
[upgrade] エラー: スキーマ差分に列・テーブルの削除が含まれています。中止します。

$(printf '%s\n' "$risky" | sed 's/^/    /')

  これを適用すると上記のデータが失われます。よくある原因:
   - プラグインを無効化/アンインストールしたまま、その列が DB に残っている
   - プラグインが新バージョン非対応で、エンティティ拡張が読み込めていない
  該当プラグインを有効なまま新バージョン対応版へ更新するか、列が不要なら
  手動で削除してから再実行してください。

  内容を確認のうえ意図的に適用する場合のみ:
    UPGRADE_ALLOW_DROP=1 bin/upgrade.sh ${ver}

  サイトはまだ公開しておらず、DB にも書き込んでいません。
  切り戻し: bin/upgrade.sh ${current:-元の値}
EOS
    exit 1
fi

echo "[upgrade] スキーマを更新します（未公開）..."
offline "スキーマ更新" doctrine:schema:update --force

echo "[upgrade] データ移行（migration）を適用します（未公開）..."
offline "migration の適用" doctrine:migrations:migrate --no-interaction --allow-no-migration

# 7) ここまで整合してから公開する。entrypoint が cache:clear を行う。
echo "[upgrade] 公開します..."
docker compose up -d

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
