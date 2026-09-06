#!/usr/bin/env bash
# 初回セットアップ: .env 作成 → シークレット生成 → 起動（配布イメージなら pull、無ければ build）。
#   使い方: bin/init.sh
#           bin/init.sh --image=ghcr.io/kurozumi/eccube-docker/ec-cube:4.3-php8.3
#                                     … build せず配布イメージを引く（数十秒。PHP はタグで選ぶ）
#           bin/init.sh --no-start    … .env を作るだけ（bin/bootstrap-server.sh が使う）
set -euo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
no_start=0
want_image=""
for a in "$@"; do
    case "$a" in
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        --no-start) no_start=1 ;;   # .env を作るだけ（サーバーの初期化。bin/bootstrap-server.sh が使う）
        --image=*)  want_image="${a#--image=}" ;;   # 配布イメージを使う（build しない）
        *) echo "[init] 不明なオプション: $a" >&2; exit 1 ;;
    esac
done
cd "$(dirname "$0")/.."
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

# ── 前提の確認。初めての人が最初につまずくところなので、日本語で「何をすればよいか」まで出す ──
if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<'EOS'
[init] Docker が見つかりません。
       Mac / Windows: Docker Desktop を入れて起動してください → https://www.docker.com/products/docker-desktop/
       Linux: https://docs.docker.com/engine/install/ の手順のあと、自分を docker グループに入れてください
EOS
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "[init] Docker は入っていますが動いていません。Docker Desktop を起動してから、もう一度 bin/init.sh を実行してください。" >&2
    exit 1
fi
cv="$(docker compose version --short 2>/dev/null || true)"
case "$cv" in
    ""|1.*|2.[0-9].*|2.1[0-9].*|2.2[0-3].*)
        echo "[init] Docker Compose が古いか無いです（いま: ${cv:-無し}。2.24 以上が要ります）。Docker Desktop を更新してください。" >&2
        exit 1 ;;
esac
# 使いたいポートが空いているか。空いていなければ次の空きを選んで .env に書く（人に .env を直させない）。
# 同じパソコンで別の店（や別の copy）を動かしていると 8080 は取られている。
port_in_use() { # port_in_use <port> → 使用中なら 0
    if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$1" >/dev/null 2>&1; return $?; fi
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}
# この実行で既に選んだポートも「使用中」扱いにする（コンテナが立つまで OS からは空いて見えるため、
# 8080 と 8081 が両方ふさがっていると両方に 8082 を選んでしまった）
taken=" "
# 結果は FREE_PORT に入れる（$( ) で受けるとサブシェルになり、taken の更新が消える）
free_port() { # free_port <希望> → FREE_PORT に空きポート（希望が使用中なら +1 ずつ探す）
    local p="$1"
    while port_in_use "$p" || [ "${taken#* $p }" != "$taken" ]; do p=$((p + 1)); done
    taken="${taken}${p} "
    FREE_PORT="$p"
}

if [ ! -f .env ]; then
    cp .env.example .env
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

# ── 秘密とポートの生成 ──
#
# **「.env を作ったかどうか」ではなく「値がまだ既定値か」で判断する。** 文書は
# `cp .env.example .env` → `bin/init.sh` の順を案内していて、その経路だと .env は既に
# あるので、以前は DB パスワードも管理者パスワードも既定値のまま素通りしていた
# （DB は eccube_pass、管理者は admin/password のまま公開一歩手前まで行けた）。
#
# ただし**すでに DB が作られていたら書き換えない。** DB のパスワードはボリュームに
# 焼かれているので、変えるとアプリが繋がらなくなる。管理者パスワードも install の
# 瞬間にしか効かない（あとから変えても嘘になる）。
env_val() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }
gen_pass() { openssl rand -hex 16; }

# この店の DB がもう作られているか（プロジェクト名 → ボリューム）
pname="$(env_val COMPOSE_PROJECT_NAME)"
if [ -z "$pname" ]; then
    # コンテナ名・ボリューム名の接頭辞。compose.yaml の name: eccube のままだと、同じパソコンに
    # 2 つ目の店を置いたとき同じ名前になり、up のたびに互いのコンテナを作り直してしまう
    pname="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/^-*//; s/-*$//')"
    [ -n "$pname" ] || pname="eccube"
    case "$pname" in eccube*) ;; *) pname="eccube-${pname}" ;; esac
    if grep -qE '^COMPOSE_PROJECT_NAME=' .env; then set_env COMPOSE_PROJECT_NAME "$pname"; else printf '\nCOMPOSE_PROJECT_NAME=%s\n' "$pname" >> .env; fi
    echo "[init] プロジェクト名: ${pname}"
fi
db_ready=0
for v in "${pname}_db_data" "${pname}_pg_data"; do
    docker volume inspect "$v" >/dev/null 2>&1 && db_ready=1
done

if [ "$db_ready" = 0 ]; then
    case "$(env_val DB_PASSWORD)" in
        ""|eccube_pass) set_env DB_PASSWORD "$(gen_pass)"; gen_db=1 ;;
    esac
    case "$(env_val DB_ROOT_PASSWORD)" in
        ""|change_me_root) set_env DB_ROOT_PASSWORD "$(gen_pass)"; gen_db=1 ;;
    esac
    [ "${gen_db:-0}" = 1 ] && echo "[init] DB_PASSWORD / DB_ROOT_PASSWORD を生成しました"
    # 初期管理者。本体の fixtures が ECCUBE_ADMIN_USER / ECCUBE_ADMIN_PASS を読む（既定 admin / password）。
    # 既定のままだと bin/publish.sh が止める（#108）。管理画面の URL も推測されにくくする
    case "$(env_val ECCUBE_ADMIN_PASS)" in
        ""|password)
            set_env ECCUBE_ADMIN_PASS "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
            case "$(env_val ECCUBE_ADMIN_ROUTE)" in ""|admin) set_env ECCUBE_ADMIN_ROUTE "admin-$(openssl rand -hex 3)" ;; esac
            echo "[init] 管理者のパスワードと管理画面の URL を生成しました（.env の ECCUBE_ADMIN_PASS / ECCUBE_ADMIN_ROUTE）" ;;
    esac
    # Redis の認証（redis プロファイルを使うときに効く。URL にも埋める。#117）
    if [ -z "$(env_val REDIS_PASSWORD)" ]; then
        redis_pass="$(gen_pass)"
        set_env REDIS_PASSWORD "$redis_pass"
        case "$(env_val REDIS_URL)" in *@*) ;; *) set_env REDIS_URL "redis://:${redis_pass}@redis:6379" ;; esac
        case "$(env_val SESSION_REDIS_URL)" in *@*) ;; *) set_env SESSION_REDIS_URL "redis://:${redis_pass}@redis-session:6379" ;; esac
        echo "[init] REDIS_PASSWORD を生成しました"
    fi
else
    echo "[init] この店の DB はもう作られているので、パスワード類はそのままにします。"
    for pair in "DB_PASSWORD=eccube_pass" "DB_ROOT_PASSWORD=change_me_root"; do
        if grep -qE "^${pair}$" .env 2>/dev/null; then
            echo "[init] 警告: ${pair%%=*} が既定値のままです。変えるなら docker compose down -v でデータごと作り直しが要ります。"
        fi
    done
fi

# ポート。使用中なら次の空きへ。**この店がもう動いているときは触らない**
# （自分自身が使っているポートを「使用中」と見て、毎回ずらしてしまうため）
if [ -z "$(docker compose ps -aq 2>/dev/null)" ]; then
    for pair in HTTP_PORT:8080 PMA_PORT:8081 MAILPIT_UI_PORT:8025; do
        key="${pair%%:*}"; want="${pair##*:}"
        cur="$(env_val "$key")"; cur="${cur:-$want}"
        free_port "$cur"; got="$FREE_PORT"
        [ "$got" != "$cur" ] && echo "[init] ポート ${cur} は使用中なので ${got} にしました（${key}）"
        if grep -qE "^${key}=" .env; then set_env "$key" "$got"; else printf '%s=%s\n' "$key" "$got" >> .env; fi
    done
fi

# --image=<参照> が来ていれば .env に書く（build せず配布イメージを引く）
if [ -n "$want_image" ]; then
    if grep -qE '^#?ECCUBE_IMAGE=' .env; then
        tmp="$(mktemp)"; sed "s|^#\{0,1\}ECCUBE_IMAGE=.*|ECCUBE_IMAGE=${want_image}|" .env > "$tmp" && mv "$tmp" .env
    else
        printf 'ECCUBE_IMAGE=%s\n' "$want_image" >> .env
    fi
    echo "[init] 配布イメージを使います: ${want_image}"
fi

if [ "$no_start" = 1 ]; then
    echo "[init] .env を用意しました（--no-start なので起動していません）。"
    exit 0
fi
if ! image_provision docker compose; then
    echo "[init] エラー: イメージを用意できませんでした。" >&2
    exit 1
fi

echo "[init] 起動します..."
if ! docker compose up -d; then
    cat >&2 <<'EOS'
[init] 起動に失敗しました。上のメッセージに "port is already allocated" があればポートの取り合いです
       （bin/init.sh は新規の .env では空きポートを選びますが、既にある .env のポートは変えません。
        .env の HTTP_PORT / PMA_PORT / MAILPIT_UI_PORT を空いている番号にしてください）。
       それ以外は docker compose logs ec-cube の最後のほうに理由が出ています。
EOS
    exit 1
fi
port="$(grep -E '^HTTP_PORT=' .env | head -1 | cut -d= -f2- || true)"; port="${port:-8080}"
route="$(grep -E '^ECCUBE_ADMIN_ROUTE=' .env | head -1 | cut -d= -f2- || true)"; route="${route:-admin}"
apass="$(grep -E '^ECCUBE_ADMIN_PASS=' .env | head -1 | cut -d= -f2- || true)"
mport="$(grep -E '^MAILPIT_UI_PORT=' .env | head -1 | cut -d= -f2- || true)"; mport="${mport:-8025}"
# 初回は EC-CUBE の取得とインストールで数分かかる。終わるまでここで待つ（人に logs を見に行かせない）
printf '[init] セットアップ中（初回は 2〜10 分）。終わるまで待ちます '
i=0; ok=0
while [ "$i" -lt 180 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null || true)"
    if [ "$code" = 200 ]; then ok=1; break; fi
    if ! docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx ec-cube; then
        echo; echo "[init] ec-cube コンテナが止まりました。理由: docker compose logs --tail 40 ec-cube" >&2; exit 1
    fi
    printf '.'; sleep 5; i=$((i + 1))
done
echo
if [ "$ok" != 1 ]; then
    echo "[init] 15 分待っても応答がありません。docker compose logs -f ec-cube で進み具合を見てください。" >&2
    exit 1
fi
cat <<EOS

[init] できました。

  お店      : http://localhost:${port}/
  管理画面  : http://localhost:${port}/${route}/
              ログイン ID: admin
              パスワード: ${apass:-（.env の ECCUBE_ADMIN_PASS）}
  メール確認: http://localhost:${mport}/  （送ったメールはここに届く。外には出ない）

  次にやること: docs/handbook.md（毎日の 3 コマンド）。困ったら bin/plugin.sh doctor
  ログイン情報は .env にも入っています（.env は git に入れないでください）
EOS
