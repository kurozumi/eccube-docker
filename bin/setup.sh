#!/usr/bin/env bash
# メールサーバーと DB サーバーを、質問に答えるだけで設定する。**先に試してから .env に書く。**
#   使い方: bin/setup.sh mail   # 送信メール（SendGrid / SES / Gmail / さくら / Resend / その他 SMTP）
#           bin/setup.sh db     # DB を外部（マネージド DB）にする。いまのデータを写すこともできる
#
# .env の書き方（MAILER_DSN の URL エンコード、DB_* と COMPOSE_FILE の組み合わせ）を人に覚えさせない。
# 試して通ったものだけ書き、書いたら起動し直す。
set -euo pipefail
# --remote=host:/path なら、向こうで同じ質問に答える（ssh -t で対話）
for a in "$@"; do case "$a" in --remote=*) r="${a#--remote=}"; exec ssh -t "${r%%:*}" "cd '${r#*:}' && bin/setup.sh ${1:-}" ;; esac; done
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/image.sh
. bin/lib/image.sh

[ -f .env ] || { echo "[setup] .env がありません。先に bin/init.sh を実行してください。" >&2; exit 1; }
set_env() { # set_env KEY VALUE（無ければ追記）
    local tmp; tmp="$(mktemp)"
    if grep -qE "^#?${1}=" .env; then sed "s|^#\{0,1\}${1}=.*|${1}=${2}|" .env > "$tmp" && mv "$tmp" .env; else rm -f "$tmp"; printf '%s=%s\n' "$1" "$2" >> .env; fi
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
proj="$(docker compose config --format json 2>/dev/null | sed -n 's/^  "name": "\(.*\)",$/\1/p' | head -1)"

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
        mv="$(env_get MARIADB_VERSION)"; mi="$(env_get MARIADB_IMAGE)"; client="${mi:-mariadb}:${mv:-10.6}"
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
    if [ "$migrate" = y ]; then
        echo "[setup] 写しています（お店は一時的に古いほうを見たままです）..."
        if [ "$engine" = postgresql ]; then
            docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"' \
              | docker run --rm -i --network "$net" -e PGPASSWORD="$pass" "$client" psql -q -v ON_ERROR_STOP=0 -h "$host" -p "$port" -U "$user" -d "$name" >/dev/null
        else
            docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump --single-transaction --triggers --no-tablespaces -u root "$MYSQL_DATABASE"' \
              | docker run --rm -i --network "$net" -e MYSQL_PWD="$pass" "$client" mysql -h "$host" -P "$port" -u "$user" "$name"
        fi
        echo "[setup] 写しました。"
    fi
    set_env DB_ENGINE "$engine"; set_env DB_HOST "$host"; set_env DB_PORT "$port"; set_env DB_NAME "$name"; set_env DB_USER "$user"; set_env DB_PASSWORD "$pass"
    files="$(grep -E '^COMPOSE_FILE=' .env | head -1 | cut -d= -f2- || true)"; files="${files:-compose.yaml:compose.override.yaml}"
    files="$(printf '%s' "$files" | tr ':' '\n' | grep -v -x 'compose.externaldb.yaml' | grep -v -x 'compose.postgresql.yaml' | paste -sd: -)"
    [ "$engine" = postgresql ] && files="${files}:compose.postgresql.yaml"
    files="${files}:compose.externaldb.yaml"; set_env COMPOSE_FILE "$files"
    echo "[setup] .env に書きました（DB_HOST=${host}、COMPOSE_FILE=${files}）。"
    docker compose stop db >/dev/null 2>&1 || true
    echo "[setup] 手元の db は止めました（データのボリュームは残っています。戻すなら COMPOSE_FILE から compose.externaldb.yaml を外して docker compose up -d）。"
    restart_app
}

restart_app() {
    echo "[setup] 設定を反映するために起動し直します..."
    docker compose up -d --remove-orphans >/dev/null 2>&1 || { echo "[setup] 起動に失敗しました: docker compose logs --tail 30 ec-cube" >&2; exit 1; }
    echo "[setup] 完了。"
}

S_ERR="$(mktemp)"; trap 'rm -f "$S_ERR"' EXIT
case "${1:-}" in
    mail) setup_mail ;;
    db)   setup_db ;;
    *) echo "使い方: bin/setup.sh mail | db"; exit 1 ;;
esac
