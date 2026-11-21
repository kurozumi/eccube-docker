#!/usr/bin/env bash
# メールサーバーと DB サーバーを、質問に答えるだけで設定する。**先に試してから .env に書く。**
#   使い方: bin/setup.sh mail   # 送信メール（SendGrid / SES / Gmail / さくら / Resend / その他 SMTP）
#           bin/setup.sh db     # DB を外部（マネージド DB）にする。いまのデータを写すこともできる
#           bin/setup.sh tunnel # Cloudflare Tunnel のトークンを、繋がることを確かめてから書く
#           bin/setup.sh backup # バックアップの送り先と暗号化の鍵を決め、1 回取って、毎日の cron に登録する
#           bin/setup.sh protect # GitHub 側で「PR と担当者の承認が無いと main に入らない」ようにする（手元で。gh が要る）
#           protect 以外は --remote=user@host:/path を付けるとサーバーで同じ質問に答えられる
#
# .env の書き方（MAILER_DSN の URL エンコード、DB_* と COMPOSE_FILE の組み合わせ）を人に覚えさせない。
# 試して通ったものだけ書き、書いたら起動し直す。
set -euo pipefail
# --remote=host:/path なら、向こうで同じ質問に答える（ssh -t で対話）
for a in "$@"; do case "$a" in --remote=*) [ "${1:-}" = protect ] && { echo "[setup] protect は手元で実行します（gh を使う）。--remote は要りません。" >&2; exit 1; }; r="${a#--remote=}"; exec ssh -t "${r%%:*}" "cd '${r#*:}' && bin/setup.sh ${1:-}" ;; esac; done
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/image.sh
. bin/lib/image.sh
# shellcheck source=lib/guard.sh
. bin/lib/guard.sh     # guard_is_prod_stack（起動し直すときに本番構成のままにする）
# shellcheck source=lib/compose.sh
. bin/lib/compose.sh   # compose_files
# shellcheck source=lib/maint.sh
. bin/lib/maint.sh     # maint_drain

[ "${1:-}" = protect ] || [ -f .env ] || { echo "[setup] .env がありません。先に bin/init.sh を実行してください。" >&2; exit 1; }
set_env() { # set_env KEY VALUE（無ければ追記）
    # **値は awk の ENVIRON で渡す。** sed の置換に素で入れると、`&` が一致した文字列に化け、`|` で sed が落ちる
    # （DB のパスワードや、`?a=1&b=2` の付いた MAILER_DSN・BACKUP_SYNC で起きる）。-v も `\` を読み替えるので使わない
    local tmp; tmp="$(mktemp)"
    if grep -qE "^#?${1}=" .env; then
        SET_K="$1" SET_V="$2" awk 'BEGIN { k = ENVIRON["SET_K"]; v = ENVIRON["SET_V"] }
            index($0, k "=") == 1 || index($0, "#" k "=") == 1 { print k "=" v; next } { print }' .env > "$tmp" && mv "$tmp" .env
    else rm -f "$tmp"; printf '%s=%s\n' "$1" "$2" >> .env; fi
}
ask() { # ask <変数名> <質問> [既定]
    local v; if [ -n "${3:-}" ]; then read -r -p "$2 [${3}]: " v; v="${v:-$3}"; else read -r -p "$2: " v; fi; printf -v "$1" '%s' "$v"
}
ask_secret() { local v; read -r -s -p "$2: " v; echo; printf -v "$1" '%s' "$v"; }
urlenc() { # URL エンコード（DSN のユーザー名・パスワード用。@ : / % + 等が入っても壊れないように）
    local s="$1" out="" i c
    for (( i = 0; i < ${#s}; i++ )); do c="${s:$i:1}"
        case "$c" in [a-zA-Z0-9.~_-]) out="${out}${c}" ;; *) out="${out}$(printf '%%%02X' "'$c")" ;; esac
    done; printf '%s' "$out"
}
proj="$( (docker compose config --format json 2>/dev/null || true) | sed -n 's/^  "name": "\(.*\)",$/\1/p' | head -1 || true)"

# ─────────────────────────────────────────────────────────────────────────────
setup_mail() {
    cat <<'EOS'
[setup] 送信メールの設定。注文メール・会員登録・パスワード再発行がここから送られます。
        先に 1 通試しに送り、届いたら .env に書きます。

  1) SendGrid            2) Amazon SES          3) Gmail / Google Workspace
  4) さくらのメール等の一般的な SMTP             5) Resend
  6) 開発用の Mailpit に戻す（外には出ない）
EOS
    ask choice "番号" 4
    host=""; port=587; user=""; pass=""; scheme="smtp"
    case "$choice" in
        1) host=smtp.sendgrid.net; user=apikey; echo "  SendGrid: ユーザー名は apikey 固定、パスワードは API キー（SG. で始まる）" ;;
        2) ask region "SES のリージョン（例: ap-northeast-1）" ap-northeast-1; host="email-smtp.${region}.amazonaws.com"; echo "  SES: SMTP 認証情報（IAM のアクセスキーではなく SMTP 用のユーザー名/パスワード）" ;;
        3) host=smtp.gmail.com; echo "  Gmail: 2 段階認証を有効にして「アプリ パスワード」を作り、それをパスワードに" ;;
        4) ask host "SMTP サーバー（例: smtp.example.com）"; ask port "ポート（587 = STARTTLS / 465 = SSL）" 587 ;;
        5) host=smtp.resend.com; user=resend; echo "  Resend: ユーザー名は resend 固定、パスワードは API キー" ;;
        6) dsn="smtp://mailpit:1025"; set_env MAILER_DSN "$dsn"; echo "[setup] MAILER_DSN=${dsn} にしました（開発用。本番では bin/publish.sh が止めます）"; restart_app; return ;;
        *) echo "[setup] 1〜6 で答えてください" >&2; exit 1 ;;
    esac
    [ -n "$user" ] || ask user "ユーザー名"
    ask_secret pass "パスワード（表示されません）"
    [ "$port" = 465 ] && scheme="smtps"
    if [ -n "$user" ]; then dsn="${scheme}://$(urlenc "$user"):$(urlenc "$pass")@${host}:${port}"; else dsn="${scheme}://${host}:${port}"; fi
    ask from "送信元アドレス（メールサービス側で確認済みのもの）"
    ask to "試しに送る先（あなたのアドレス）" "$from"
    echo "[setup] 試しに送っています（${host}:${port}）..."
    if MAILER_DSN_TEST="$dsn" MAIL_FROM="$from" MAIL_TO="$to" docker compose run --rm --no-deps -T \
        -e MAILER_DSN_TEST -e MAIL_FROM -e MAIL_TO --entrypoint php ec-cube <<'PHP' 2>&1 | grep -v Deprecated | tail -3
<?php
require '/var/www/html/vendor/autoload.php';
try {
    $t = Symfony\Component\Mailer\Transport::fromDsn(getenv('MAILER_DSN_TEST'));
    $m = (new Symfony\Component\Mime\Email())->from(getenv('MAIL_FROM'))->to(getenv('MAIL_TO'))
        ->subject('[eccube-docker] 送信テスト')->text("このメールが届けば、お店からのメールは送れます。\n" . date('c'));
    $t->send($m); echo "SENT\n";
} catch (Throwable $e) { echo "FAILED: " . $e->getMessage() . "\n"; exit(1); }
PHP
    then
        set_env MAILER_DSN "$dsn"
        echo "[setup] 届いていれば完了です。.env に MAILER_DSN を書きました。"
        restart_app
    else
        echo "[setup] 送れませんでした。上のメッセージが理由です（多いのは: パスワード違い、ポート違い、送信元が未確認）。.env は変えていません。" >&2
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
setup_db() {
    cat <<'EOS'
[setup] DB の設定。
  1) この環境の中の DB を使う（既定。何もしなくてよい）
  2) 外部の DB（マネージド DB。RDS / Cloud SQL / さくら / ConoHa 等）に切り替える
EOS
    ask choice "番号" 1
    [ "$choice" = 2 ] || { echo "[setup] このままです。"; return; }
    cur_engine="$(env_get DB_ENGINE)"; cur_engine="${cur_engine:-mysql}"
    ask engine "種類（mysql = MariaDB / MySQL、postgresql）" "$cur_engine"
    case "$engine" in mysql|postgresql) ;; *) echo "[setup] mysql か postgresql です" >&2; exit 1 ;; esac
    ask host "ホスト名（例: db.example.com）"
    [ "$engine" = postgresql ] && dport=5432 || dport=3306
    ask port "ポート" "$dport"; ask name "データベース名" "$(env_get DB_NAME)"; ask user "ユーザー名" "$(env_get DB_USER)"
    ask_secret pass "パスワード（表示されません）"
    echo "[setup] 接続を試しています（${host}:${port}）..."
    net="${proj}_backend"; docker network inspect "$net" >/dev/null 2>&1 || net=bridge
    if [ "$engine" = postgresql ]; then
        pgv="$(env_get PG_VERSION)"; client="postgres:${pgv:-16}-alpine"
        docker run --rm --network "$net" -e PGPASSWORD="$pass" "$client" psql -h "$host" -p "$port" -U "$user" -d "$name" -c 'SELECT 1' >/dev/null 2>"$S_ERR" || { echo "[setup] 繋がりません: $(tail -1 "$S_ERR")" >&2; exit 1; }
    else
        mv="$(env_get MARIADB_VERSION)"; mi="$(env_get MARIADB_IMAGE)"; client="${mi:-mariadb}:${mv:-10.11}"
        docker run --rm --network "$net" -e MYSQL_PWD="$pass" "$client" mysql -h "$host" -P "$port" -u "$user" "$name" -e 'SELECT 1' >/dev/null 2>"$S_ERR" || { echo "[setup] 繋がりません: $(tail -1 "$S_ERR")" >&2; exit 1; }
    fi
    echo "[setup] 繋がりました。"
    # いまのデータを写すか（手元の db が動いていて、種類が同じときだけ）
    migrate=n
    if [ -n "$(docker compose ps -q db 2>/dev/null)" ] && [ "$engine" = "$cur_engine" ]; then
        ask migrate "いまの DB のデータ（商品・会員・注文）を新しい DB へ写しますか？ [y/N]" n
    elif [ -n "$(docker compose ps -q db 2>/dev/null)" ]; then
        echo "[setup] 注意: 種類が違う（${cur_engine} → ${engine}）ので、データは写せません。新しい DB は空から始まります。"
    fi
    # 向き先にもう店があるか。**写すならその DB の表は上書きされ**（向き先を取り違えると、別の店の本番 DB を
    # 消す）、**写さないならその店のデータでこのまま動き出す**（別の店の DB に書き始める）。どちらでも見る。
    # 写すときは DB 名を打たせ、写す前にその DB の中身を backups/ へ取る。
    if [ "$engine" = postgresql ]; then
        tshop="$(docker run --rm --network "$net" -e PGPASSWORD="$pass" "$client" psql -h "$host" -p "$port" -U "$user" -d "$name" -tAc "SELECT to_regclass('dtb_base_info') IS NOT NULL" 2>/dev/null || echo unknown)"
    else
        tshop="$(docker run --rm --network "$net" -e MYSQL_PWD="$pass" "$client" mysql -N -h "$host" -P "$port" -u "$user" "$name" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'dtb_base_info'" 2>/dev/null || echo unknown)"
    fi
    tshop="$(printf '%s' "$tshop" | tr -d '[:space:]')"
    if [ "$migrate" != y ] && [ "$tshop" != f ] && [ "$tshop" != 0 ]; then
        echo "[setup] **向き先の DB（${name}@${host}）には、もう店があります**（または確かめられませんでした）。"
        echo "        写さずに切り替えると、お店はその DB のデータ（商品・会員・注文）で動き出します。"
        ask confirm_name "その DB の店で動かすなら、データベース名（${name}）を打ってください"
        [ "$confirm_name" = "$name" ] || { echo "[setup] 中止しました（何も変えていません）。"; exit 1; }
    fi
    if [ "$migrate" = y ]; then
        case "$tshop" in
            f|0) ;;
            *)
                echo "[setup] **写す先の DB（${name}@${host}）には、もう店があります**（または確かめられませんでした）。"
                echo "        写すと、その DB の表は上書きされます。写す前に、その DB の中身を backups/ へ取ります。"
                ask confirm_name "よければ、写す先のデータベース名（${name}）を打ってください"
                [ "$confirm_name" = "$name" ] || { echo "[setup] 中止しました（何も変えていません）。"; exit 1; }
                # 名前は backup.sh の世代管理に数えられない形にする（完全なバックアップではないので、ほかの
                # 世代と一緒に数えて消さない・消されない）。中身は個人情報なので持ち主だけが読める
                tdir="backups/$(date +%Y%m%d-%H%M%S)-setup-db-target"
                mkdir -p backups && mkdir -m 700 "$tdir" || { echo "[setup] ${tdir} を作れません。中止します（何も変えていません）。" >&2; exit 1; }
                echo "[setup] 写す先の DB を ${tdir}/ へ取っています..."
                if [ "$engine" = postgresql ]; then
                    docker run --rm --network "$net" -e PGPASSWORD="$pass" "$client" pg_dump --clean --if-exists --no-owner --no-privileges -h "$host" -p "$port" -U "$user" "$name" | gzip > "${tdir}/db.sql.gz" \
                        || { echo "[setup] 写す先の DB を取れませんでした。中止します（何も変えていません）。" >&2; exit 1; }
                else
                    docker run --rm --network "$net" -e MYSQL_PWD="$pass" "$client" mysqldump --single-transaction --triggers --no-tablespaces -h "$host" -P "$port" -u "$user" "$name" | gzip > "${tdir}/db.sql.gz" \
                        || { echo "[setup] 写す先の DB を取れませんでした。中止します（何も変えていません）。" >&2; exit 1; }
                fi
                gunzip -c "${tdir}/db.sql.gz" | tail -c 1024 | grep -qE -- '-- (PostgreSQL database dump complete|Dump completed)' \
                    || { echo "[setup] 写す先の DB のダンプが最後までありません。中止します（何も変えていません）。" >&2; exit 1; }
                chmod 600 "${tdir}/db.sql.gz"
                # BACKUP_ENCRYPT_KEY があれば、ほかのバックアップと同じ形で暗号化して平文を残さない（#118）
                tkey="$(env_get BACKUP_ENCRYPT_KEY)"
                if [ -n "$tkey" ]; then
                    BACKUP_ENCRYPT_KEY="$tkey" openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 600000 -salt \
                        -pass env:BACKUP_ENCRYPT_KEY -in "${tdir}/db.sql.gz" -out "${tdir}/db.sql.gz.enc" \
                        || { echo "[setup] 写す先の DB のダンプを暗号化できませんでした。中止します（何も変えていません）。" >&2; exit 1; }
                    rm -f "${tdir}/db.sql.gz"; chmod 600 "${tdir}/db.sql.gz.enc"
                fi
                echo "[setup] 取りました: ${tdir}/（この DB 単独のダンプ。外へも控えておくこと。戻すなら同じクライアントで流し込む）。"
                ;;
        esac
    fi
    if [ "$migrate" = y ]; then
        # **写している間はメンテナンス表示。** 以前は「お店は古いほうを見たまま」で、写してから切り替える
        # までに入った注文は古い DB にしか無く、切り替えたあとの店から消えていた。
        sm=/var/www/html/.maintenance; smine=0; switched=0; setup_done=0
        stoken="$(openssl rand -hex 16)"
        if [ -n "$(docker compose ps -q --status running ec-cube 2>/dev/null)" ] && ! docker compose exec -T ec-cube test -f "$sm" 2>/dev/null; then
            docker compose exec -T ec-cube runuser -u www-data -- sh -c "printf 'setup:%s' '${stoken}' > $sm" \
                || { echo "[setup] メンテナンス表示を立てられませんでした。注文を受けたまま写さないよう、中止します（何も変えていません）。" >&2; exit 1; }
            smine=1; echo "[setup] メンテナンス ON（写している間、お客さんには「メンテナンス中」）"
        fi
        setup_maint_off() {
            if [ "$smine" = 1 ] && docker compose exec -T ec-cube sh -c "grep -qE '^setup(-switched)?:' $sm && rm -f $sm" 2>/dev/null; then
                echo "[setup] メンテナンス OFF"
            fi
            return 0
        }
        # 途中で止まった・Ctrl-C でも、表示を黙って残さない。切り替える前なら外す（お店はいままでの DB のまま）。
        # 切り替えたあとなら、壊れた画面を出さないよう残して、外し方を出す
        setup_on_exit() {
            rm -f "$S_ERR"   # 全体の EXIT の後始末を、この trap が置き換えるので
            # .env を書いている途中で終わった（Ctrl-C・切断など）なら、控えから戻してから後始末する
            if [ "${env_writing:-0}" = 1 ]; then env_writing=0; undo_env; fi
            # .env の控えは、戻せたときだけ消す（戻せなかったら、手で戻すために残す）
            [ "${keep_envbak:-0}" = 1 ] || rm -f "${S_ERR}.env"
            [ "$smine" = 1 ] && [ "$setup_done" != 1 ] || return 0
            if [ "$switched" = 0 ]; then
                setup_maint_off
            else
                echo "[setup] **メンテナンス表示を残しています**（新しい DB で開くことを確かめられませんでした）。" >&2
                echo "        確かめてから外す: docker compose exec ec-cube rm /var/www/html/.maintenance" >&2
            fi
        }
        trap setup_on_exit EXIT
        if ! maint_drain docker compose; then
            echo "[setup] 注意: 処理中の要求が 30 秒で終わりませんでした（ログイン中の管理者の操作かもしれません）。このまま写します。"
        fi
        echo "[setup] 写しています..."
        copy_ok=1
        if [ "$engine" = postgresql ]; then
            # 1 つのトランザクションで流し、エラーで止める（途中で失敗したら写す先は流す前のまま）
            docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump --clean --if-exists --no-owner --no-privileges -U "$POSTGRES_USER" "$POSTGRES_DB"' \
              | docker run --rm -i --network "$net" -e PGPASSWORD="$pass" "$client" psql -q -v ON_ERROR_STOP=1 --single-transaction -h "$host" -p "$port" -U "$user" -d "$name" >/dev/null || copy_ok=0
        else
            docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump --single-transaction --triggers --no-tablespaces -u root "$MYSQL_DATABASE"' \
              | docker run --rm -i --network "$net" -e MYSQL_PWD="$pass" "$client" mysql -h "$host" -P "$port" -u "$user" "$name" || copy_ok=0
        fi
        if [ "$copy_ok" != 1 ]; then
            setup_maint_off
            echo "[setup] 写せませんでした。.env は変えていません（お店はいままでの DB のまま）。" >&2
            [ -n "${tdir:-}" ] && echo "        写す先の DB が途中まで書き換わっているかもしれません。元の中身: ${tdir}/db.sql.gz" >&2
            exit 1
        fi
        echo "[setup] 写しました。"
    fi
    files="$(grep -E '^COMPOSE_FILE=' .env | head -1 | cut -d= -f2- || true)"; files="${files:-compose.yaml:compose.override.yaml}"
    files="$(printf '%s' "$files" | tr ':' '\n' | grep -v -x 'compose.externaldb.yaml' | grep -v -x 'compose.postgresql.yaml' | paste -sd: -)"
    [ "$engine" = postgresql ] && files="${files}:compose.postgresql.yaml"
    files="${files}:compose.externaldb.yaml"
    # .env はまとめて書き、途中で失敗したら書く前に戻す（新しい DB_HOST に古い DB_PASSWORD、のような半端を残さない）
    cp -p .env "${S_ERR}.env"
    undo_env() { # 書く前の .env に戻す。戻せなければ控えと表示を残して、手で戻す道を出す
        if cp -p "${S_ERR}.env" .env; then
            rm -f "${S_ERR}.env"
            echo "[setup] .env は書く前のままです（お店はいままでの DB のまま）。" >&2
        else
            keep_envbak=1; switched=1   # 表示も外さない（.env が半端なまま開けない）
            echo "[setup] エラー: .env を戻せませんでした（ディスクがいっぱい、など）。書く前の .env: ${S_ERR}.env" >&2
            echo "        空きを作ってから: cp ${S_ERR}.env .env" >&2
        fi
    }
    # データを写さないときは setup_on_exit が無いので、書いている途中の中断（Ctrl-C・切断など）はここで戻す
    if [ "$migrate" != y ]; then
        trap 'rm -f "$S_ERR"; if [ "${env_writing:-0}" = 1 ]; then env_writing=0; undo_env; fi; [ "${keep_envbak:-0}" = 1 ] || rm -f "${S_ERR}.env"' EXIT
    fi
    env_writing=1
    if ! { set_env DB_ENGINE "$engine" && set_env DB_HOST "$host" && set_env DB_PORT "$port" && set_env DB_NAME "$name" &&
           set_env DB_USER "$user" && set_env DB_PASSWORD "$pass" && set_env COMPOSE_FILE "$files"; }; then
        echo "[setup] エラー: .env に書けませんでした。" >&2
        env_writing=0; undo_env
        exit 1
    fi
    # 表示の印を変える。**切り替えたあとの表示は、新しい DB で開くと確かめるまで外さない。** doctor は setup: を
    # 「切り替える前に止まった残り」として外すので、そのままだと確かめていない DB でお店を開けてしまう。
    # 変えられなければ、切り替えずに戻す（まだ作り直していないので、お店はいままでの DB で動いている）
    if [ "$migrate" = y ] && [ "${smine:-0}" = 1 ] &&
       ! docker compose exec -T ec-cube sh -c "if grep -q '^setup:' $sm; then printf 'setup-switched:%s' '${stoken}' > $sm; else grep -q '^setup-switched:' $sm; fi" 2>/dev/null; then
        echo "[setup] エラー: メンテナンス表示の印を変えられませんでした。切り替えずに戻します。" >&2
        env_writing=0; undo_env
        exit 1
    fi
    env_writing=0
    rm -f "${S_ERR}.env"
    switched=1
    echo "[setup] .env に書きました（DB_HOST=${host}、COMPOSE_FILE=${files}）。"
    docker compose stop db >/dev/null 2>&1 || true
    echo "[setup] 手元の db は止めました（データのボリュームは残っています。戻すなら COMPOSE_FILE から compose.externaldb.yaml を外して docker compose up -d）。"
    restart_app
    # 表示はボリュームの中にあるので、作り直したあとも残っている。**新しい DB で開くのを確かめてから外す**
    # （token の cookie で中から見る。deploy.sh と同じ）
    if [ "$migrate" = y ] && [ "${smine:-0}" = 1 ]; then
        echo "[setup] 新しい DB で開くかを確かめています..."
        sport="$(docker compose port nginx 80 2>/dev/null | tail -1 | sed -E 's/^(0\.0\.0\.0|\[::\]):/localhost:/' || true)"
        [ -n "$sport" ] || sport="localhost:$(env_get HTTP_PORT)"
        scode=000
        for _ in $(seq 1 60); do
            scode="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' -b "maintenance_token=${stoken}" "http://${sport}/" || echo 000)"
            [ "$scode" = 200 ] && break
            sleep 5
        done
        if [ "$scode" = 200 ] && ! docker compose exec -T ec-cube runuser -u www-data -- php bin/console doctrine:migrations:up-to-date --no-interaction >/dev/null 2>&1; then
            # 開いても、未適用の migration が残っている（または確かめられない）DB でお店を開けない。表示の中では起動時の
            # migration も流れないので、deploy.sh に任せる（退避してから流し、終われば表示も外す）
            echo "[setup] 新しい DB で開きましたが、未適用の migration があるか、確かめられませんでした。" >&2
            echo "        bin/deploy.sh で流してください（メンテナンス表示は、そのとき外れます）。" >&2
            exit 1
        elif [ "$scode" = 200 ]; then
            setup_done=1
            setup_maint_off
        else
            echo "[setup] エラー: 新しい DB で開きませんでした（${scode}）。ログ: docker compose logs --tail 30 ec-cube" >&2
            exit 1
        fi
    fi
    setup_done=1
    trap 'rm -f "$S_ERR"' EXIT   # 全体の後始末に戻す
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
setup_tunnel() {
    cat <<'EOS'
[setup] Cloudflare Tunnel。ポートを開けず、A レコードも証明書も触らずに、ドメインで公開します。
        Cloudflare の画面でやること（先に済ませてください）:
          1. Zero Trust → Networks → Tunnels → Create a tunnel（Cloudflared）→ 名前を付ける
          2. 表示されるコマンドの中の、eyJ… で始まる長い文字列がトークン
          3. Public Hostname に あなたのドメイン → Type: HTTP、URL: nginx:80
        ここではトークンを受け取り、**本当に繋がるか試してから** .env に書きます。
EOS
    ask_secret token "トークン（eyJ… 貼り付け。表示されません）"
    case "$token" in eyJ*) ;; *) echo "[setup] トークンは eyJ で始まります。コマンド全体ではなく、--token の後ろの文字列だけを貼ってください。" >&2; exit 1 ;; esac
    img="$(grep -m1 'image: cloudflare/cloudflared' compose.prod.yaml | awk '{print $2}')"; img="${img:-cloudflare/cloudflared:latest}"
    echo "[setup] 繋がるか試しています（20 秒ほど）..."
    # timeout コマンドは macOS に無いので、裏で動かして 20 秒後にログを読む
    cname="eccube-tunnel-test-$$"; docker rm -f "$cname" >/dev/null 2>&1 || true
    docker run -d --name "$cname" -e TUNNEL_TOKEN="$token" "$img" tunnel --no-autoupdate run >/dev/null 2>&1 || true
    sleep 20; out="$(docker logs "$cname" 2>&1 || true)"; docker rm -f "$cname" >/dev/null 2>&1 || true
    if printf '%s' "$out" | grep -q 'Registered tunnel connection'; then
        echo "[setup] 繋がりました。"
    else
        echo "[setup] 繋がりません。cloudflared の最後の出力:" >&2; printf '%s\n' "$out" | tail -4 | cut -c1-160 | sed 's/^/           /' >&2
        echo "           トークンが違う（別のトンネルのもの、コピー漏れ）か、そのトンネルが削除されています。.env は変えていません。" >&2; exit 1
    fi
    set_env TUNNEL_TOKEN "$token"
    prof="$(env_get COMPOSE_PROFILES)"
    case ",${prof}," in *,tunnel,*) ;; *) set_env COMPOSE_PROFILES "${prof:+${prof},}tunnel"; echo "[setup] COMPOSE_PROFILES に tunnel を足しました" ;; esac
    echo "[setup] .env に TUNNEL_TOKEN を書きました。公開は bin/publish.sh（すでに公開中なら起動し直します）。"
    if [ -n "$(docker compose ps -q ec-cube 2>/dev/null)" ]; then restart_app; fi
}

# ─────────────────────────────────────────────────────────────────────────────
setup_backup() {
    cat <<'EOS'
[setup] バックアップ。毎日 1 回、DB・画像・管理画面が書いたファイル・.env を退避して、サーバーの外へ送ります。
        送り先:
          1) rclone（Google Drive / Dropbox / Amazon S3 / Cloudflare R2 / Backblaze 等）
          2) 別のサーバー（rsync over ssh。user@host:/path）
          3) このマシンの別の場所 / マウント済みの NAS（/mnt/… のようなパス）
          4) 外へは送らない（backups/ に置くだけ。サーバーごと失うと一緒に消えます）
EOS
    ask choice "番号" 1
    sync=""
    case "$choice" in
        1)  if ! command -v rclone >/dev/null 2>&1; then
                echo "[setup] rclone が入っていません。入れてから、もう一度:" >&2
                echo "           Mac: brew install rclone   /   Linux: curl https://rclone.org/install.sh | sudo bash" >&2; exit 1
            fi
            if [ -z "$(rclone listremotes 2>/dev/null)" ]; then
                echo "[setup] rclone の送り先（remote）がまだ無いので、rclone の設定を始めます（n → 名前 → サービスを選ぶ → 認証）。"
                rclone config
            fi
            echo "[setup] いまある送り先:"; rclone listremotes | sed 's/^/           /'
            ask remote "使う送り先の名前（末尾の : は要らない）"; remote="${remote%:}"
            ask sub "その中の置き場所（例: backups/myshop）" "backups/$(basename "$PWD")"
            echo "[setup] 試しています..."; rclone mkdir "${remote}:${sub}" && rclone lsd "${remote}:" >/dev/null || { echo "[setup] ${remote}: に書けません。rclone config で設定を確かめてください。" >&2; exit 1; }
            sync="rclone:${remote}:${sub}" ;;
        2)  ask dest "送り先（user@host:/path）"; h="${dest%%:*}"; d="${dest#*:}"
            echo "[setup] 試しています..."; ssh -o ConnectTimeout=10 "$h" "mkdir -p '$d' && test -w '$d'" || { echo "[setup] ${dest} に書けません（ssh の鍵、パス、権限）。" >&2; exit 1; }
            sync="$dest" ;;
        3)  ask dest "パス（例: /mnt/nas/myshop）"; mkdir -p "$dest" && [ -w "$dest" ] || { echo "[setup] ${dest} に書けません。" >&2; exit 1; }; sync="$dest" ;;
        4)  sync="" ;;
        *)  echo "[setup] 1〜4 で答えてください" >&2; exit 1 ;;
    esac
    set_env BACKUP_SYNC "$sync"
    if [ -z "$(env_get BACKUP_ENCRYPT_KEY)" ]; then
        key="$(openssl rand -base64 32)"; set_env BACKUP_ENCRYPT_KEY "$key"
        cat <<EOS
[setup] 暗号化の鍵を作って .env に書きました。**この鍵を無くすとバックアップは全部読めなくなります。**
        パスワードマネージャに控えてください:
          BACKUP_ENCRYPT_KEY=${key}
EOS
    fi
    echo "[setup] いま 1 回取ってみます..."
    bin/backup.sh || { echo "[setup] 取れませんでした。上のメッセージが理由です。" >&2; exit 1; }
    ask cron "毎日 4:00 に自動で取るよう、この環境の cron に登録しますか？ [Y/n]" Y
    if [ "$cron" != n ] && [ "$cron" != N ]; then
        line="0 4 * * * cd $(pwd) && bin/backup.sh >> var/backup.log 2>&1"
        if crontab -l 2>/dev/null | grep -Fq "cd $(pwd) && bin/backup.sh"; then echo "[setup] cron には登録済みです。"
        else ( crontab -l 2>/dev/null; printf '%s\n' "$line" ) | crontab - && mkdir -p var && echo "[setup] cron に登録しました: ${line}"; fi
    fi
    echo "[setup] 完了。取れているかは backups/ と、送り先の中身で確かめられます。"
}

# ─────────────────────────────────────────────────────────────────────────────
# GitHub 側の壁。main に直接 push できなくし、PR と担当者（CODEOWNERS）の承認を必須にする。
# サーバー側の壁（bin/deploy.sh）と合わせて鉄壁になる。片方だけでも意味はある。
#
# **非公開リポジトリだと有料プランが要る**（個人は Pro、組織は Team 以上）。無料だと API が
# 403 で「Upgrade」と返す。その場合はサーバー側の壁だけになる（それでも、手元から本番へは
# origin/main の先頭と同じものしか送れない）。
setup_protect() {
    command -v gh >/dev/null 2>&1 || { echo "[setup] gh（GitHub CLI）が必要です: https://cli.github.com/" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "[setup] gh でログインしてください: gh auth login" >&2; exit 1; }
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$repo" ] || { echo "[setup] origin が GitHub のリポジトリではありません（この店のリポジトリで実行してください）" >&2; exit 1; }
    branch="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
    me="$(gh api user -q .login)"
    cat <<EOS
[setup] ${repo} の ${branch} を守ります。入れるルール:
          - ${branch} へ直接 push できない（PR が必須）。force push と削除も禁止
          - PR は担当者（CODEOWNERS）の承認が無いとマージできない。承認後に push し直したら承認は無効
          - 未解決のレビューコメントが残っているとマージできない
          - 例外なし（リポジトリの管理者も同じ）
        担当者が自分で作った PR は、自分では承認できません（GitHub の仕様）。
        一人で運用していて承認者が居ないなら、承認の人数を 0 にすると「PR は要るが承認は要らない」になります。
EOS
    ask owners "承認する担当者の GitHub ユーザー名（複数はカンマ区切り）" "$me"
    ask count "承認に必要な人数" 1
    case "$count" in 0|1|2|3) ;; *) echo "[setup] 0〜3 で答えてください" >&2; exit 1 ;; esac
    handles="$(printf '%s' "$owners" | tr ',' '\n' | sed 's/^[[:space:]]*@\{0,1\}//; s/[[:space:]]*$//' | grep . | sed 's/^/@/' | tr '\n' ' ' | sed 's/ $//')"
    codeowners="# 本番へ出るブランチの承認者。bin/setup.sh protect が書いた。
# どのファイルの変更も、ここに居る人の承認が無いとマージできない。
*   ${handles}
"
    # CODEOWNERS はリポジトリに入っていないと効かない。ルールを入れる前なら直接置ける
    # （入れた後は PR でしか入らない）。
    existing_rule="$(gh api "repos/${repo}/rulesets" -q '.[] | select(.name == "eccube-docker: 本番へ出るブランチを守る") | .id' 2>/dev/null | head -1 || true)"
    if ! gh api "repos/${repo}/contents/.github/CODEOWNERS?ref=${branch}" >/dev/null 2>&1; then
        if [ -z "$existing_rule" ]; then
            echo "[setup] .github/CODEOWNERS を ${branch} に置きます..."
            gh api -X PUT "repos/${repo}/contents/.github/CODEOWNERS" \
                -f message="CODEOWNERS: 本番へ出るブランチの承認者（bin/setup.sh protect）" \
                -f branch="$branch" \
                -f content="$(printf '%s' "$codeowners" | base64 | tr -d '\n')" >/dev/null \
                || { echo "[setup] CODEOWNERS を置けませんでした。手で .github/CODEOWNERS を作って push してください:" >&2; printf '%s' "$codeowners" >&2; exit 1; }
            echo "[setup] 置きました（手元は git pull で取り込んでください）"
        else
            mkdir -p .github; printf '%s' "$codeowners" > .github/CODEOWNERS
            echo "[setup] ルールは既にあるので、.github/CODEOWNERS は手元に書きました。**PR で ${branch} に入れてください**（入るまで承認者の指定は効きません）"
        fi
    else
        echo "[setup] .github/CODEOWNERS は既にあります（変えるなら PR で）"
    fi
    [ "$count" -gt 0 ] && owner_review=true || owner_review=false
    body="$(cat <<EOS
{
  "name": "eccube-docker: 本番へ出るブランチを守る",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": ${count},
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": ${owner_review},
        "require_last_push_approval": ${owner_review},
        "required_review_thread_resolution": true } }
  ]
}
EOS
)"
    if [ -n "$existing_rule" ]; then
        echo "[setup] ルールを更新します（id ${existing_rule}）..."
        out="$(printf '%s' "$body" | gh api -X PUT "repos/${repo}/rulesets/${existing_rule}" --input - 2>&1)" && ok=1 || ok=0
    else
        echo "[setup] ルールを入れます..."
        out="$(printf '%s' "$body" | gh api -X POST "repos/${repo}/rulesets" --input - 2>&1)" && ok=1 || ok=0
    fi
    if [ "$ok" != 1 ]; then
        echo "[setup] 入れられませんでした:" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        if printf '%s' "$out" | grep -qiE 'upgrade|403|not available|plan'; then
            cat >&2 <<EOS
[setup] 非公開リポジトリのブランチ保護には有料プラン（個人は Pro、組織は Team 以上）が要ります。
        入れない場合も、サーバー側の壁は効きます:
          - 手元から本番へは origin/${branch} の先頭と同じものしか送れない（bin/deploy.sh）
          - 本番はプロジェクト名を打たないと反映されず、誰が何を出したかが var/deploy.log に残る
        ただし「${branch} へ直接 push する」ことは止められないので、運用で守ってください
        （エンジニアには PR を出してもらい、${branch} へ push できるのは担当者だけ、と決める）。
EOS
        fi
        exit 1
    fi
    cat <<EOS
[setup] 入れました。https://github.com/${repo}/settings/rules で見られます。
        これで ${branch} には PR でしか入れず、${handles} の承認（${count} 人）が要ります。
        本番へ出るのは bin/deploy.sh が ${branch} の先頭を送るときだけです（docs/deploy.md）。
EOS
}


restart_app() {
    echo "[setup] 設定を反映するために起動し直します..."
    # **本番なら本番構成のまま起動し直す。** 素の `docker compose up -d` は .env の COMPOSE_FILE（開発用の
    # compose.override.yaml を含む）で作り直し、--remove-orphans が caddy / cloudflared を消していた
    # （deploy.sh / upgrade.sh と同じ判定。止まっているときは判定できないので、いまの COMPOSE_FILE のまま）
    local files
    if guard_is_prod_stack; then files="$(compose_files --prod)"; else files="$(compose_files)"; fi
    # shellcheck disable=SC2086  # compose_files は -f の並びを単語分割させる
    docker compose $files up -d --remove-orphans >/dev/null 2>&1 || { echo "[setup] 起動に失敗しました: docker compose logs --tail 30 ec-cube" >&2; exit 1; }
    echo "[setup] 完了。"
}

S_ERR="$(mktemp)"; trap 'rm -f "$S_ERR"' EXIT
case "${1:-}" in
    mail)   setup_mail ;;
    db)     setup_db ;;
    tunnel) setup_tunnel ;;
    backup) setup_backup ;;
    protect) setup_protect ;;
    *) echo "使い方: bin/setup.sh mail | db | tunnel | backup [--remote=user@host:/path] | protect"; exit 1 ;;
esac
