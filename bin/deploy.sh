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
#   bin/deploy.sh --rebuild             ローカル build の環境で、イメージも作り直す（土台の PHP / Debian の
#                                      パッチを取り込む。数分）。配布イメージの環境では毎回引き直すので要らない
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
#   0. イメージ              配布イメージなら引き直す（--rebuild ならローカル build し直す）。
#                            **メンテナンスより前に**やる（数分かかりうるので、古いサイトのまま待つ）
#   1. メンテナンス ON        .maintenance を deploy:<token> で作る。ログイン中の管理者は素通り
#   2. bin/backup.sh         管理画面が本番で書いたものを含めて退避（backups/<日時>-before-deploy/）。
#                            **表示の中で取る**（取ってから表示までの注文が退避から漏れないように）
#   3. git pull --ff-only    自分のリポジトリから取り込む。衝突したら何も変えずに OFF して止まる
#   4. docker compose up -d  compose / .env / イメージが変わっていれば作り直す（同じなら何もしない）
#   4b. 設定ファイル         nginx / caddy の設定が前回と違えば、確かめてから再起動（up -d は作り直さない）。
#                            DB の設定は再起動が要ることだけを言う
#   5. migration             app/DoctrineMigrations（CustomizeMigrations）と本体の未適用分
#   5b. プラグインの DB      ファイルだけ新しくなったプラグインを DB に追いつかせる（bin/plugin.sh sync）。
#                            版が変わったものは本体の更新処理、エンティティだけ変わったものはスキーマ更新。
#                            打たないと、列を足した版で画面が「Column not found」の 500 になる
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

do_pull=1; do_backup=1; do_rebuild=0; remote=""; mode=auto; check=0; sent_sha=""; sent_by=""; sent_note=""
for a in "$@"; do
    case "$a" in
        --no-pull)   do_pull=0 ;;
        --no-backup) do_backup=0 ;;
        --check)     check=1 ;;
        --rebuild)   do_rebuild=1 ;;
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
    [ "$do_rebuild" = 1 ] && args="$args --rebuild"
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

# ── 0. イメージ ──
# **タグの名前ではなく、イメージの ID で比べる。** 追跡タグ（…/ec-cube:4.3）は毎週焼き直されても
# 名前が変わらない。以前は動いているコンテナの .Config.Image（＝タグ名）と ECCUBE_IMAGE を
# 文字列で比べていたので、両者はいつも一致し、焼き直しを一度も引かなかった
# （CVE-2026-109618/109619 の修正版が出ても、本番は古い PHP のままだった）。
# 引いておけば、ID が変わったコンテナは 4. の up -d が作り直す。
#
# ローカル build の環境（ECCUBE_IMAGE 無し）は、作り直さない限り PHP が古いまま。
# 毎回 build すると数分かかるので --rebuild のときだけにして、それ以外はイメージの古さを見せる。
#
# メンテナンスより前にやるのは、引き直しも build も数分かかりうるから。その間は古いサイトのまま動く。
img_running="$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)"
if image_uses_registry; then
    log "配布イメージを引き直します: $(image_ref)"
    if ! "${dc[@]}" pull --quiet ec-cube; then
        # 届かないのは GHCR の障害か回線。手元に同じ参照のイメージがあるなら、コードの反映まで
        # 止める理由にはしない。**無ければ止める。** そのまま進むと 4. の up -d が compose.yaml の
        # build: を見て手元で build し、配布物ではないイメージで公開してしまう
        # （しかもメンテナンス ON のあとで、数分かかってから落ちうる）。
        docker image inspect "$(image_ref)" >/dev/null 2>&1 \
            || die "配布イメージ $(image_ref) を取得できず、手元にもありません。何も変えていません。
       ECCUBE_IMAGE のタグが正しいか、サーバーから ghcr.io に届くかを確かめてください。"
        log "注意: 引き直せませんでした。いま手元にあるイメージのまま進めます。"
    fi
elif [ "$do_rebuild" = 1 ]; then
    log "イメージを作り直します（土台の PHP / Debian のパッチを取り込みます。数分かかります）..."
    "${dc[@]}" build --pull ec-cube || die "イメージを作り直せませんでした。何も変えていません（サイトは古いまま動いています）。"
else
    built="$(docker image inspect --format '{{.Created}}' "$(image_ref)" 2>/dev/null | cut -c1-10 || true)"
    log "イメージは手元で build したもの（${built:-作成日不明}）。PHP のパッチは作り直さないと入りません。"
    log "  取り込むには: bin/deploy.sh --rebuild（週に 1 回が目安。docs/deploy.md）"
fi
# ミドルウェア（nginx / redis / DB / caddy / cloudflared …）も引き直す。
# **compose の `up -d` は、同じ名前のイメージが手元にあれば取りに行かない。** nginx:1.30-alpine の
# ような系列タグは上流がパッチ版で作り直しても名前が変わらないので、引き直さない限り最初に
# 引いた日の版のまま残る（NGINX2Root の 1.30.7 が出ても 1.30.x の古いままになる）。
# build: を持つサービス（ec-cube / worker）は上で扱ったので除く。届かなくても止めない
# （手元のイメージで動き続けられる。古いだけで、壊れはしない）。
log "ミドルウェアのイメージを引き直します..."
if ! "${dc[@]}" pull --quiet --ignore-buildable --ignore-pull-failures; then
    log "注意: 一部のイメージを引き直せませんでした。手元にあるイメージのまま進めます。"
fi

img_new="$(docker image inspect --format '{{.Id}}' "$(image_ref)" 2>/dev/null || true)"
if [ -n "$img_new" ] && [ -n "$img_running" ] && [ "$img_new" != "$img_running" ]; then
    log "  イメージが新しくなっています（${img_running#sha256:} → ${img_new#sha256:}）。4. で作り直します。" | sed -E 's/([0-9a-f]{12})[0-9a-f]{52}/\1/g'
fi

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
    if [ -n "${backup_dir:-}" ]; then
        echo "         DB も始める前に戻すなら: bin/restore.sh ${backup_dir}" >&2
        echo "         （メンテナンス表示の中で取ったので、その後の注文はありません）" >&2
    fi
}

# ── 1. メンテナンス ON → 退避 ──
# **表示を先に立ててから退避を取る。** 逆だと、取ってから表示までの間に入った注文が退避に無く、
# migration が壊れて退避から戻したときに、その注文が消える。
maint_on
# 退避の途中で Ctrl-C・ssh の切断があっても、表示を出しっぱなしにしない（まだ何も変えていない）
backup_interrupted() {
    trap - INT TERM HUP
    rm -f "${bk_result:-}"
    maint_off
    deploy_record "${planned:-?}" "$([ -d .git ] && echo pull || echo push)" "$by" "failed${sent_note:-} (backup interrupted)"
    die "退避の途中で止められました。何も変えていません。"
}
if [ "$do_backup" = 1 ]; then
    trap backup_interrupted INT TERM HUP
    log "退避します（DB・画像・管理画面が書いたファイル）..."
    # **出力を捨てない。** backup.sh は「管理画面が書いたのにコミットされていないファイル」を
    # 挙げる。deploy はそれを上書きしない（pull は同じファイルを触らない限り通る）が、
    # サーバーにしか無い状態が続く。ここで見せて、手元へ取り込む導線を出す。
    # 退避は backups/<日時>-before-deploy/（毎日の世代とは別に数える。backup.sh の BACKUP_LABEL）
    bk_result="$(mktemp)"
    if ! out="$(BACKUP_LABEL=deploy BACKUP_RESULT_FILE="$bk_result" bin/backup.sh 2>&1)"; then
        printf '%s\n' "$out" | tail -5 >&2
        rm -f "$bk_result"
        trap - INT TERM HUP
        maint_off
        deploy_record "${planned:-?}" "$([ -d .git ] && echo pull || echo push)" "$by" "failed${sent_note:-} (backup)"
        die "退避に失敗しました。何も変えていません。bin/backup.sh を単体で打って原因を見てください。"
    fi
    if printf '%s\n' "$out" | grep -q 'コミットされていない変更'; then
        printf '%s\n' "$out" | sed -n '/コミットされていない変更/,/入っています/p'
        log "  手元へ取り込むには（あなたのパソコンで）: bin/pull-admin-files.sh <host>:<path>"
    fi
    backup_dir="$(cat "$bk_result")"; rm -f "$bk_result"
    trap - INT TERM HUP
    log "退避先: ${backup_dir}"
fi
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

# ── 3b. 新しい compose が使うイメージ ──
# **0. で引いたのは pull する前の compose のイメージ。** サーバーで git pull する形では、新しい compose が
# 別のイメージ（MariaDB の既定 10.6 → 10.11 など）を指すと、それは手元に無い。4. は配布イメージの環境で
# --pull never なので、そのまま進むと up が「イメージが無い」で落ち、メンテナンスが ON のまま残る。
# 手元に無いものだけを引く（普段は 1 つも無いので、待たせない）。ec-cube / worker（＝配布イメージ）は
# 0. で扱ったので除く。ローカル build の環境は 4. に --pull never が付かず、up が自分で引くので要らない。
if image_uses_registry; then
    missing=()
    while IFS= read -r ref; do
        [ -n "$ref" ] && [ "$ref" != "$(image_ref)" ] || continue
        docker image inspect "$ref" >/dev/null 2>&1 || missing+=("$ref")
    done < <("${dc[@]}" config --images 2>/dev/null | sort -u)
    if [ "${#missing[@]}" -gt 0 ]; then
        log "新しい compose が使うイメージを引きます: ${missing[*]}"
        for ref in "${missing[@]}"; do
            if ! docker pull --quiet "$ref" >/dev/null; then
                echo "[deploy] エラー: イメージ ${ref} を取得できませんでした（新しい compose が使うもの）。サーバーから届くかを確かめてください。" >&2
                trap - ERR
                on_fail
                exit 1
            fi
        done
    fi
fi

# ── 4. compose / イメージ ──
log "コンテナを揃えます（compose / .env が同じなら何も起きません）..."
# 配布イメージでは build も pull もさせない。0. で用意したイメージだけを使う。
# --no-build だけでは、compose が足りないと見たイメージを自分で pull しに行く。0. の pull が
# 失敗して手元のイメージで進むと決めたあとに、ここでもう一度 pull して落ちる（メンテナンス ON の
# あとで）、を避けるため --pull never も付ける。
up_opts=(); image_uses_registry && up_opts=(--no-build --pull never)
"${dc[@]}" up -d ${up_opts[@]+"${up_opts[@]}"} --remove-orphans >/dev/null 2>&1 || "${dc[@]}" up -d ${up_opts[@]+"${up_opts[@]}"}
# 作り直された場合、entrypoint（migrate + cache:clear）が終わるまで待つ
for i in $(seq 1 60); do
    st="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q ec-cube)" 2>/dev/null || echo unknown)"
    [ "$st" = "healthy" ] && break
    sleep 3
done

# ── 4b. nginx / caddy / DB の設定ファイル ──
# **4. の up -d は、bind mount した設定ファイルが変わっても作り直さない**（イメージも compose も同じだから）。
# nginx は起動のときにしか設定を読まず、1 ファイルの bind mount は Linux ではファイルが入れ替わると古い中身を
# 見続ける。v1.0.18 で静的ファイルのキャッシュを 30 日 → 5 分にしたとき、deploy しても効かなかった。
# 前回に当てた設定の指紋を var/deploy-conf/ に置き、違えば確かめてから再起動する（1 秒ほど止まる）。
# 指紋が無い初回も再起動する（いま動いているのが、どの版の設定か分からないため）。
# 確かめで落ちたら再起動しない（古い設定の nginx が動き続け、メンテナンス表示のまま止まる）。
# DB は再起動すると接続が全部切れるので、自分では再起動せず、変わったことだけを言う。
conf_stamp_dir=var/deploy-conf
sha256_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-64; }
conf_hash() { # conf_hash <ファイル…>（無いものは飛ばす）
    # ファイルごとに指紋を取り、「名前 指紋」の並びの指紋にする。中身をつないでから取ると、ファイルの
    # 境目が動いても（a の末尾が b の先頭へ移る）同じ値になり、MariaDB のようにファイルごとに読む設定の変更を見落とす
    # 無いファイルは飛ばす（&& でつなぐと最後が無いとき失敗で返り、pipefail で deploy が落ちる）。
    # **読めないファイルは失敗にする。** 空の指紋を記録すると、その後の変更をずっと見落とす
    local f d
    for f in "$@"; do
        [ -f "$f" ] || continue
        d="$(sha256_stdin < "$f")" || exit 1   # パイプの左側（サブシェル）を抜け、pipefail で失敗が返る
        printf '%s %s\n' "$f" "$d"
    done | LC_ALL=C sort | sha256_stdin
}
service_running() { [ -n "$("${dc[@]}" ps -q --status running "$1" 2>/dev/null)" ]; }
apply_proxy_conf() { # apply_proxy_conf <サービス> <設定ファイル> <確かめるコマンド…>
    local svc="$1" file="$2" now old out stamp="${conf_stamp_dir}/$1.sha256"
    shift 2
    [ -f "$file" ] && service_running "$svc" || return 0
    now="$(conf_hash "$file")" || { echo "[deploy] エラー: ${file} を読めません（持ち主と権限を確かめてください）。" >&2; return 1; }
    old="$(cat "$stamp" 2>/dev/null || true)"
    [ "$now" = "$old" ] && return 0
    log "${svc} の設定（${file}）を当てます。確かめてから再起動します（1 秒ほど止まります）..."
    if ! out="$("${dc[@]}" run --rm --no-deps -T "$svc" "$@" 2>&1)"; then
        echo "$out" | grep -v -e '^ *Container ' -e 'docker-entrypoint' | tail -n 20 >&2
        echo "[deploy] エラー: ${file} に誤りがあります。${svc} は古い設定のまま動いています。直してもう一度 bin/deploy.sh を打ってください。" >&2
        return 1
    fi
    if ! out="$("${dc[@]}" restart "$svc" 2>&1)"; then
        echo "$out" >&2
        return 1
    fi
    echo "$now" > "$stamp"
}
mkdir -p "$conf_stamp_dir"
apply_proxy_conf nginx docker/nginx/default.conf nginx -t
apply_proxy_conf caddy docker/caddy/Caddyfile caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# PostgreSQL の db はこの設定を mount していないので、言わない（再起動しても何も変わらない）
db_id="$("${dc[@]}" ps -q --status running db 2>/dev/null || true)"
if [ -n "$db_id" ] && docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$db_id" 2>/dev/null | grep -q '/etc/mysql/conf.d'; then
    db_now="$(conf_hash docker/mariadb/conf.d/*.cnf)" || { echo "[deploy] エラー: docker/mariadb/conf.d の設定を読めません（持ち主と権限を確かめてください）。" >&2; false; }
    db_old="$(cat "${conf_stamp_dir}/db.sha256" 2>/dev/null || true)"
    if [ -n "$db_old" ] && [ "$db_now" != "$db_old" ]; then
        log "注意: DB の設定（docker/mariadb/conf.d）が変わりました。動いている DB には、再起動するまで効きません。"
        log "      お客さんの少ない時間に: ${dc[*]} restart db（数秒、接続が切れます）"
    fi
    echo "$db_now" > "${conf_stamp_dir}/db.sha256"
fi

# ── 5. migration ──
log "migration を適用します..."
ec php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration

# ── 5b. プラグインの DB ──
# `git -C app/Plugin/<Code> pull` などでファイルだけ新しくした版が列やテーブルを足していると、
# 本体の更新処理を通っていないので DB に無い。キャッシュを組み立てる前にやる（組み立ては列を読む）。
log "プラグインの DB を確かめます（ファイルだけ新しくなったものがあれば追いつかせます）..."
PLUGIN_SYNC_NO_SETTLE=1 bin/plugin.sh sync

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
