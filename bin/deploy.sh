#!/usr/bin/env bash
# 自分のコードをサーバーに反映する（日常のデプロイ）。
#
#   bin/deploy.sh                       このサーバーで: 退避 → メンテ ON → pull → 反映 → 確認 → メンテ OFF
#   bin/deploy.sh --remote host:/path   手元から: ssh でそこへ行って同じことをする
#   bin/deploy.sh --no-pull             pull せず、いま置いてあるコードを反映するだけ
#   bin/deploy.sh --no-backup           退避を飛ばす（普段は付けない。5 秒で終わる）
#
# **EC-CUBE 本体の版を上げるのはこれではなく bin/upgrade.sh。**
# こちらは「自分のコード（app/ html/user_data）を直したので反映したい」用で、
# ボリュームは作り直さず、DB も画像も触らない。
#
# やること（順番に意味がある）:
#   1. bin/backup.sh         管理画面が本番で書いたものを含めて退避（戻せる状態を先に作る）
#   2. メンテナンス ON        .maintenance を deploy:<token> で作る。ログイン中の管理者は素通り
#   3. git pull --ff-only    自分のリポジトリから取り込む。衝突したら何も変えずに OFF して止まる
#   4. docker compose up -d  compose / .env / イメージが変わっていれば作り直す（同じなら何もしない）
#   5. migration             app/DoctrineMigrations（CustomizeMigrations）と本体の未適用分
#   6. proxy の生成          エンティティ拡張（プラグインのトレイト）を反映
#   7. キャッシュ            プール → OPcache → warmup（bin/plugin.sh reload と同じ）
#   8. 疎通確認             落ちていれば **OFF にしない。** 壊れた画面より 503 のほうがまし
#   9. メンテナンス OFF
#
# 途中で失敗したら ON のまま止まる。直してもう一度 bin/deploy.sh を打てばよい
# （pull は済んでいれば何もしない、migration は適用済みを飛ばす、proxy と
# キャッシュは作り直す、と全部やり直せる）。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

log() { echo "[deploy] $*"; }
die() { echo "[deploy] エラー: $*" >&2; exit 1; }

do_pull=1; do_backup=1; remote=""
for a in "$@"; do
    case "$a" in
        --no-pull)   do_pull=0 ;;
        --no-backup) do_backup=0 ;;
        --remote=*)  remote="${a#--remote=}" ;;
        --remote)    die "--remote=host:/path の形で指定してください" ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "不明なオプション: $a" ;;
    esac
done

# ── 手元から: ssh で向こうへ行って同じことをする ──
if [ -n "$remote" ]; then
    host="${remote%%:*}"; path="${remote#*:}"
    [ "$host" != "$remote" ] || die "--remote=host:/path の形で指定してください"
    args=""
    [ "$do_pull" = 0 ] && args="$args --no-pull"
    [ "$do_backup" = 0 ] && args="$args --no-backup"
    log "${host} の ${path} で実行します"
    exec ssh -t "$host" "cd '${path}' && bin/deploy.sh${args}"
fi

# ── 前提 ──
cid="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"
[ -n "$cid" ] || die "ec-cube が動いていません。初回は bin/init.sh または bin/publish.sh。
       別名のスタックで動いているなら .env に COMPOSE_PROJECT_NAME=<名前> を書いてください。"

# 本番構成で動いていれば本番構成のまま扱う（開発構成に落として公開しないため。upgrade.sh と同じ）
dc=(docker compose)
if guard_is_prod_stack; then
    dc=(docker compose -f compose.yaml -f compose.prod.yaml)
fi

MAINT=/var/www/html/.maintenance
ec() { docker compose exec -T ec-cube runuser -u www-data -- "$@"; }

# token は疎通確認でも使う。本体の index.php は cookie の maintenance_token が
# ファイルの token と一致すれば、メンテナンス中でも通常どおり応答する
# （管理者が素通りできる仕組みと同じ）。これが無いと確認が 503 を見て必ず失敗する。
token=""
maint_on() {
    # 手で入れたメンテナンスがあれば上書きしない（そのまま ON なので目的は果たせる）。
    # その token を借りて疎通確認する。
    if docker compose exec -T ec-cube test -f "$MAINT" 2>/dev/null; then
        token="$(docker compose exec -T ec-cube sh -c "cut -d: -f2 $MAINT" 2>/dev/null | tr -d '\r\n' || true)"
        log "メンテナンス表示はすでに有効です（そのまま進めます）"
        return 0
    fi
    token="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"
    ec sh -c "printf 'deploy:%s' '$token' > $MAINT"
    log "メンテナンス ON（お客さんには「メンテナンス中」。ログイン中の管理者は見えます）"
}
maint_off() {
    # deploy: が付いているものだけ消す。手で入れたものは残す（doctor と同じ区別）
    if docker compose exec -T ec-cube sh -c "grep -q '^deploy:' $MAINT" 2>/dev/null; then
        ec rm -f "$MAINT"
        log "メンテナンス OFF"
    fi
}
on_fail() {
    echo >&2
    echo "[deploy] 失敗しました。**メンテナンス表示は ON のままです**（壊れた画面を公開しないため）。" >&2
    echo "         直してから、もう一度 bin/deploy.sh を打ってください（途中からやり直せます）。" >&2
    echo "         原因が分からなければ: bin/plugin.sh doctor" >&2
    if [ -n "${before:-}" ] && [ "${before:-}" != "${after:-}" ]; then
        echo "         直前のコードに戻すなら: git checkout ${before} && bin/deploy.sh --no-pull" >&2
    fi
}

# ── 1. 退避 ──
if [ "$do_backup" = 1 ]; then
    log "退避します（DB・画像・管理画面が書いたファイル）..."
    bin/backup.sh >/dev/null || die "退避に失敗しました。何も変えていません。bin/backup.sh を単体で打って原因を見てください。"
    log "退避先: $(ls -1d backups/*/ 2>/dev/null | sort | tail -1)"
fi

# ── 2. メンテナンス ON ──
maint_on
trap on_fail ERR

# ── 3. pull ──
before="$(git rev-parse --short HEAD 2>/dev/null || echo '')"
if [ "$do_pull" = 1 ]; then
    if [ -d .git ]; then
        log "自分のリポジトリから取り込みます（git pull --ff-only）..."
        if ! git pull --ff-only --quiet; then
            trap - ERR
            maint_off
            die "取り込めませんでした。何も変えていません。
       よくある原因: 本番で管理画面が書き換えたファイル（customize.css など）と、
       手元で直した同じファイルがぶつかっている。
         git status          で何がぶつかっているか
         git stash           で本番側の変更を一旦よけて、もう一度 bin/deploy.sh
       （よけた分は git stash pop で戻せる。backups/ にも入っている）"
        fi
    else
        log "git 管理ではないので pull は飛ばします（置いてあるコードを反映）"
    fi
fi
after="$(git rev-parse --short HEAD 2>/dev/null || echo '')"
if [ -n "$before" ] && [ "$before" = "$after" ]; then
    log "コード: ${after}（変更なし。設定とキャッシュの反映だけ行います）"
else
    log "コード: ${before:-?} → ${after:-?}"
    git --no-pager log --oneline "${before}..${after}" 2>/dev/null | sed 's/^/           /' || true
fi

# ── 4. compose / イメージ ──
running_img="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
if image_uses_registry && [ "$(image_ref)" != "$running_img" ]; then
    log "配布イメージが変わっています: ${running_img} → $(image_ref)"
    image_provision "${dc[@]}"
fi
log "コンテナを揃えます（compose / .env が同じなら何も起きません）..."
"${dc[@]}" up -d --remove-orphans >/dev/null 2>&1 || "${dc[@]}" up -d
# 作り直された場合、entrypoint（migrate + cache:clear）が終わるまで待つ
for i in $(seq 1 60); do
    st="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q ec-cube)" 2>/dev/null || echo unknown)"
    [ "$st" = "healthy" ] && break
    sleep 3
done

# ── 5. migration ──
log "migration を適用します..."
ec php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration

# ── 6. proxy ──
log "エンティティ proxy を生成します..."
ec php bin/console eccube:generate:proxies

# ── 7. キャッシュ ──
log "キャッシュを消して温め直します（数分かかります。止めないでください）..."
bin/plugin.sh reload

# ── 7b. プラグインテンプレートの写しの差分 ──
# app/template/plugin/ の写しはプラグインを更新しても勝ち続ける。ここで見せる。
if [ -f app/template/plugin/.base ]; then
    log "プラグインテンプレートの写しと、プラグイン側との差分:"
    bin/plugin.sh template diff || true
fi

# ── 8. 疎通 ──
# メンテナンス中なので bin/healthcheck.sh は 503 を見てしまう。token cookie を付けて
# 本体を通し、フロントと商品一覧が実際に描画できるかを見る（管理画面はもともと素通り）。
log "画面が開くか確かめます（メンテナンス表示の裏で）..."
port="$(grep -E '^HTTP_PORT=' .env 2>/dev/null | cut -d= -f2- || true)"; port="${port:-8080}"
ok=0
for i in $(seq 1 20); do
    ok=1
    for path in / /products/list; do
        code="$(curl -s -o /dev/null -w '%{http_code}' -b "maintenance_token=${token}" "http://localhost:${port}${path}" || echo 000)"
        case "$code" in 200|301|302) ;; *) ok=0; last="${code} ${path}" ;; esac
    done
    [ "$ok" = 1 ] && break
    sleep 3
done
if [ "$ok" != 1 ]; then
    echo "[deploy] 画面が開きません: ${last:-?}" >&2
    false   # → on_fail（ON のまま）
fi

# ── 9. メンテナンス OFF ──
trap - ERR
maint_off
log "完了。${after:-?} を公開しています。"
log "管理画面とフロントを目で確認してください。"
