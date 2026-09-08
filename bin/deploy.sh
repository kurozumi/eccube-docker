#!/usr/bin/env bash
# 自分のコードをサーバーに反映する（日常のデプロイ）。
#
#   bin/deploy.sh                       このサーバーで: 退避 → メンテ ON → pull → 反映 → 確認 → メンテ OFF
#   bin/deploy.sh --remote=host:/path  手元から。サーバーに .git があれば向こうで git pull（今までどおり）、
#                                      無ければ**手元から rsync で送る**（サーバーに GitHub の鍵が要らない。
#                                      bin/bootstrap-server.sh が整えたサーバーはこちら）。--push / --pull で強制
#   bin/deploy.sh --no-pull             pull せず、いま置いてあるコードを反映するだけ
#   bin/deploy.sh --no-backup           退避を飛ばす（普段は付けない。5 秒で終わる）
#   bin/deploy.sh --check               何が出るかを見るだけ。何も変えない（--remote と組み合わせ可）
#
# **本番（compose.prod.yaml で動いているスタック）には、レビュー済みのものしか出ない。**
#   - 手元から送るとき（push モード）: いまのブランチが DEPLOY_BRANCH（既定 main）で、
#     コミットしていない変更が無く、origin/<branch> の先頭と**完全に同じ**でなければ送れない。
#     エンジニアが自分のブランチや作業中のファイルを本番へ送ることを、ここで止める
#   - サーバーで pull するとき: いるブランチが DEPLOY_BRANCH でなければ止まる
#   - どちらも、出るコミットと注意の要るファイル（migration / compose / プラグイン）を見せ、
#     **プロジェクト名を打たないと進まない**（y では通さない。指が覚えて通してしまうため）。
#     非対話なら CONFIRM_DEPLOY=<プロジェクト名>
#   - 誰が・いつ・何を出したかを、サーバーの var/deploy.log に残す
#   緊急で main 以外を出すなら DEPLOY_UNREVIEWED=<プロジェクト名>（記録に UNREVIEWED と残る）。
#   GitHub 側で「PR と承認が無いと main に入らない」ようにするのは bin/setup.sh protect。
#   詳細は docs/deploy.md「誰が・何を・どうやって本番へ出すか」。
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
# shellcheck source=lib/compose.sh
. "$(dirname "$0")/lib/compose.sh"
# shellcheck source=lib/deploy-guard.sh
. "$(dirname "$0")/lib/deploy-guard.sh"

log() { echo "[deploy] $*"; }
die() { echo "[deploy] エラー: $*" >&2; exit 1; }

do_pull=1; do_backup=1; remote=""; mode=auto; check=0; sent_sha=""; sent_by=""; sent_note=""
for a in "$@"; do
    case "$a" in
        --no-pull)   do_pull=0 ;;
        --no-backup) do_backup=0 ;;
        --check)     check=1 ;;
        --push)      mode=push ;;
        --pull)      mode=pull ;;
        --sha=*)     sent_sha="${a#--sha=}" ;;   # 内部用: push モードで手元が送った sha
        --by=*)      sent_by="${a#--by=}" ;;     # 内部用: push モードで送った人
        --note=*)    sent_note=" ${a#--note=}" ;; # 内部用: 記録に添える印（UNREVIEWED）
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
    args=""; envs=""
    [ "$do_backup" = 0 ] && args="$args --no-backup"
    [ "$check" = 1 ] && args="$args --check"
    # サーバーに .git が無ければ「手元から送る」（push）。サーバーに GitHub の鍵を置かなくてよい
    # （bin/bootstrap-server.sh が整えたサーバーはこの形）。あれば今までどおり向こうで git pull。
    if [ "$mode" = auto ]; then
        if ssh "$host" "test -d '${path}/.git'" 2>/dev/null; then mode=pull; else mode=push; fi
    fi
    # 向こうが本番かを先に見る。本番なら、送れるものを絞る。
    #   0 … 本番構成で稼働中  1 … 開発/検証  それ以外 … 判定できない（止まっている・まだ無い）
    # **判定できないものを「本番ではない」と扱わない**（guard.sh と同じ考え）。
    probe="$(ssh "$host" "cd '${path}' 2>/dev/null && . bin/lib/guard.sh && guard_is_prod_stack; echo \"rc=\$?\"; guard_project_name" 2>/dev/null || true)"
    rprod="$(printf '%s\n' "$probe" | sed -n 's/^rc=//p' | tail -1)"
    rproj="$(printf '%s\n' "$probe" | grep -v '^rc=' | tail -1)"
    case "$rprod" in 0) target=prod ;; 1) target=dev ;; *) target=unknown ;; esac
    if [ "$mode" = push ]; then
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "手元が git のリポジトリではありません（push モードは git が追跡しているファイルを送ります）"
        command -v rsync >/dev/null 2>&1 || die "rsync が必要です（Mac は最初から入っています。Linux: apt install rsync）"
        sha="$(git rev-parse HEAD 2>/dev/null || echo '')"
        branch="$(deploy_branch)"
        if [ "$target" != dev ]; then
            case "$target" in
                prod)    log "向こうは本番構成です。出せるのは origin/${branch} の先頭と同じものだけです。確かめます..." ;;
                unknown) log "向こうが本番かどうか判定できません（止まっている、または初回）。本番として扱います。確かめます..." ;;
            esac
            if ! deploy_guard_local "$branch"; then
                if [ "$check" = 1 ]; then
                    log "  このままでは本番には出せません（--check なので要約まで出します）"
                elif [ -n "$rproj" ] && [ "${DEPLOY_UNREVIEWED:-}" = "$rproj" ]; then
                    log "DEPLOY_UNREVIEWED を確認しました。**レビューされていないものを本番へ出します**（記録に残ります）。"
                    sent_note=" UNREVIEWED"
                else
                    die "本番には出せません。上の項目を直してから（正しい道: PR → 承認 → ${branch} にマージ → git pull → bin/deploy.sh）。
       緊急でどうしても出すなら DEPLOY_UNREVIEWED=${rproj:-<プロジェクト名>} を付けて実行（記録に UNREVIEWED と残ります）。"
                fi
            else
                log "  ✓ ${branch} の先頭（${sha:0:7}）と同じです。コミットしていない変更もありません。"
            fi
        else
            if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
                log "注意: コミットしていない変更も、いまの中身のまま送ります（開発/検証サーバーなので通します）"
            fi
        fi
        # 何が出るか（向こうの記録にある最後の sha からの差分）
        last="$(ssh "$host" "cd '${path}' 2>/dev/null && awk -F'\t' '\$5 == \"done\" { s = \$2 } END { if (s != \"\" && s != \"?\") print s }' var/deploy.log 2>/dev/null" 2>/dev/null | tail -1 || true)"
        log "出るもの（${host}:${path}、${target}）:"
        deploy_preview "$last" "$sha"
        if [ "$check" = 1 ]; then log "--check なので、ここまで。何も送っていません。"; exit 0; fi
        # 本番の確認は**送る前**に取る。送ってから断られると、向こうのファイルだけ新しい状態が残るため
        if [ "$target" != dev ]; then
            deploy_confirm "${rproj:-$(basename "$path")}" || exit 1
            envs="CONFIRM_DEPLOY='${rproj:-$(basename "$path")}' "
        fi
        stamp="$(date +%Y%m%d-%H%M%S)"
        log "${host}:${path} へ送ります（git が追跡しているファイル。上書きされる分は向こうの var/deploy-prev/${stamp}/ に残す）..."
        ssh "$host" "mkdir -p '${path}'" || die "${host} に入れません（ssh の設定を確認）"
        git ls-files -z | rsync -az --from0 --files-from=- --backup --backup-dir="var/deploy-prev/${stamp}" ./ "${host}:${path}/" \
            || die "送れませんでした。何も反映していません（向こうはまだ古いままです）"
        args="$args --no-pull --sha=${sha} --by=$(deploy_whoami)"
        [ -n "$sent_note" ] && args="$args --note=${sent_note# }"
    elif [ "$do_pull" = 0 ]; then
        args="$args --no-pull"
    fi
    log "${host} の ${path} で実行します（${mode}）"
    exec ssh -t "$host" "cd '${path}' && ${envs}bin/deploy.sh${args}"
fi

# ── 前提 ──
cid="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"
[ -n "$cid" ] || die "ec-cube が動いていません。初回は bin/init.sh または bin/publish.sh。
       別名のスタックで動いているなら .env に COMPOSE_PROJECT_NAME=<名前> を書いてください。"

# 本番構成で動いていれば本番構成のまま扱う（開発構成に落として公開しないため。upgrade.sh と同じ）
# shellcheck disable=SC2046  # compose_files は -f の並びを単語分割させる
dc=(docker compose $(compose_files))
if guard_is_prod_stack; then
    dc=(docker compose $(compose_files --prod))
fi

MAINT=/var/www/html/.maintenance
ec() { docker compose exec -T ec-cube runuser -u www-data -- "$@"; }

# ── 0. 本番の守り ──
# 何が出るかを先に見せ、本番ならプロジェクト名を打たせる。ここまでは何も変えない。
is_prod=0; guard_is_prod_stack && is_prod=1
proj="$(guard_project_name)"; proj="${proj:-$(basename "$PWD")}"
branch="$(deploy_branch)"
by="${sent_by:-$(deploy_whoami)}"
planned=""
if [ -d .git ] && [ "$do_pull" = 1 ]; then
    cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    if [ "$is_prod" = 1 ] && [ "$cur" != "$branch" ]; then
        if [ "${DEPLOY_UNREVIEWED:-}" = "$proj" ]; then
            log "DEPLOY_UNREVIEWED を確認しました。**${cur} を本番へ出します**（記録に残ります）。"
            sent_note=" UNREVIEWED"
        else
            die "本番のサーバーが ${cur:-?} にいます。本番へ出せるのは ${branch} だけです。
       git checkout ${branch} してから。緊急で出すなら DEPLOY_UNREVIEWED=${proj}（記録に残ります）。"
        fi
    fi
    git fetch --quiet origin "$cur" 2>/dev/null || die "origin/${cur} を取得できません（サーバーから GitHub に届いていない、または鍵が無い）"
    planned="$(git rev-parse "origin/${cur}" 2>/dev/null || echo '')"
    log "出るもの（${proj}、$([ "$is_prod" = 1 ] && echo 本番 || echo 開発/検証)）:"
    deploy_preview "$(git rev-parse HEAD)" "$planned"
elif [ -d .git ]; then
    planned="$(git rev-parse HEAD 2>/dev/null || echo '')"
    log "出るもの（${proj}、pull なし）: いま置いてあるコード ${planned:0:7}"
else
    planned="$sent_sha"
    last="$(deploy_last_sha)"
    log "出るもの（${proj}、$([ "$is_prod" = 1 ] && echo 本番 || echo 開発/検証)）: ${planned:-?}${last:+（前回 ${last:0:7}）}"
fi
if [ "$check" = 1 ]; then log "--check なので、ここまで。何も変えていません。"; exit 0; fi
if [ "$is_prod" = 1 ]; then
    deploy_confirm "$proj" || exit 1
fi
deploy_record "${planned:-?}" "$([ -d .git ] && echo pull || echo push)" "$by" "start${sent_note:-}"

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
    deploy_record "${after:-${planned:-?}}" "$([ -d .git ] && echo pull || echo push)" "$by" "failed${sent_note:-}"
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
    # **出力を捨てない。** backup.sh は「管理画面が書いたのにコミットされていないファイル」を
    # 挙げる。deploy はそれを上書きしない（pull は同じファイルを触らない限り通る）が、
    # サーバーにしか無い状態が続く。ここで見せて、手元へ取り込む導線を出す。
    out="$(bin/backup.sh 2>&1)" || { printf '%s\n' "$out" | tail -5 >&2; die "退避に失敗しました。何も変えていません。bin/backup.sh を単体で打って原因を見てください。"; }
    if printf '%s\n' "$out" | grep -q 'コミットされていない変更'; then
        printf '%s\n' "$out" | sed -n '/コミットされていない変更/,/入っています/p'
        log "  手元へ取り込むには（あなたのパソコンで）: bin/pull-admin-files.sh <host>:<path>"
    fi
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
            deploy_record "${planned:-?}" pull "$by" "failed${sent_note} (pull)"
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
after="$(git rev-parse --short HEAD 2>/dev/null || echo "${sent_sha:0:7}")"
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
deploy_record "$(git rev-parse HEAD 2>/dev/null || echo "${sent_sha:-?}")" "$([ -d .git ] && echo pull || echo push)" "$by" "done${sent_note:-}"
log "完了。${after:-?} を公開しています。（記録: var/deploy.log）"
log "管理画面とフロントを目で確認してください。"
