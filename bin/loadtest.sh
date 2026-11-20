#!/usr/bin/env bash
# フロントに負荷をかけて、何 PV/秒まで耐えるか・どこが先に詰まるかを測る（k6。docs/loadtest.md）。
#
#   bin/loadtest.sh smoke                          動くかだけ（1 PV/秒・30 秒）。最初に必ずこれ
#   bin/loadtest.sh load   --rate=50               山 50 PV/秒まで上げて 5 分保つ
#   bin/loadtest.sh stress --rate=100              山の 25% 刻みで 150% まで。どこで崩れるかを見る
#   bin/loadtest.sh spike  --rate=100              平常（10%）から 10 秒で山へ（セールの開始・メルマガの直後）
#
#   --url=http://...     相手（既定は手元の http://127.0.0.1:<HTTP_PORT>）
#   --rate=N             山の PV/秒（閲覧の分。既定 10）
#   --duration=5m        load の山を保つ時間      --ramp=2m   load の上り時間
#   --cart-ratio=0.1     閲覧に対する「カートに入れる」の割合（1 回で 3 PV。0 で流さない）
#   --p95=1000           合格とする 95 パーセンタイルの応答時間（ms）
#   --max-vus=N          同時に待てる仮想ユーザーの上限（既定 rate × 20）
#
# **手元（127.0.0.1 / localhost）以外へは、相手のホスト名を打たないと流さない。** 本番へ流すと、
# 自分で自分のサイトを落とすことになる（お客さんが入れない）。Cloudflare などの前段が攻撃と見て
# 止めることもある。非対話なら CONFIRM_LOADTEST=<ホスト名>。**自分が運用しているサイトにだけ**流すこと。
#
# カートに入れる流れは、DB にカートの行（dtb_cart）とセッションを作る。注文までは流さない。
#
# 結果は var/loadtest/<日時>-<流し方>/ に残る（要約・JSON・条件・手元ならコンテナの CPU / メモリ）。
# 合格の線を割ると終了コード 99（k6 と同じ）。
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"

log() { echo "[loadtest] $*"; }
die() { echo "[loadtest] エラー: $*" >&2; exit 1; }

# k6 の版は固定する（結果を前回と比べられるように。シナリオの書き方も版で変わる）
K6_IMAGE="grafana/k6:2.3.0@sha256:2dd4756ec6e14e62778916e1eb850108e4b499304c02df56760fa0bdb0fba0b8"

profile="${1:-}"
case "$profile" in
    smoke|load|stress|spike) shift ;;
    "") die "流し方を指定してください: smoke / load / stress / spike（bin/loadtest.sh --help）" ;;
    *) die "不明な流し方: ${profile}（smoke / load / stress / spike）" ;;
esac

port="$(env_get HTTP_PORT)"
url="http://127.0.0.1:${port:-8080}"
rate=10; duration=5m; ramp=2m; cart_ratio=0.1; p95=1000; max_vus=""
for a in "$@"; do
    case "$a" in
        --url=*)        url="${a#--url=}" ;;
        --rate=*)       rate="${a#--rate=}" ;;
        --duration=*)   duration="${a#--duration=}" ;;
        --ramp=*)       ramp="${a#--ramp=}" ;;
        --cart-ratio=*) cart_ratio="${a#--cart-ratio=}" ;;
        --p95=*)        p95="${a#--p95=}" ;;
        --max-vus=*)    max_vus="${a#--max-vus=}" ;;
        *) die "不明なオプション: $a" ;;
    esac
done
url="${url%/}"
case "$url" in http://*|https://*) ;; *) die "--url は http:// か https:// で始めてください: $url" ;; esac
case "$rate" in ''|*[!0-9]*) die "--rate は整数で: $rate" ;; esac
[ "$rate" -ge 1 ] || die "--rate は 1 以上で"

hostport="${url#*://}"; hostport="${hostport%%/*}"
host="${hostport%%:*}"
case "$host" in
    127.0.0.1|localhost|::1|\[::1\]) local_target=1 ;;
    *) local_target=0 ;;
esac

# ── 手元以外へ流すときの確認 ──
if [ "$local_target" = 0 ]; then
    echo "[loadtest] 相手は ${host} です（手元ではありません）。"
    echo "           流し方 ${profile}、山 ${rate} PV/秒。お客さんが使っているサイトなら、そのあいだ遅くなるか落ちます。"
    echo "           前段（Cloudflare など）が攻撃と見て止めることがあります。**自分が運用しているサイトにだけ**流してください。"
    if [ -n "${CONFIRM_LOADTEST:-}" ]; then
        [ "$CONFIRM_LOADTEST" = "$host" ] || die "CONFIRM_LOADTEST（${CONFIRM_LOADTEST}）が相手のホスト名（${host}）と違います。"
    elif [ -t 0 ]; then
        printf '[loadtest] 流すなら、相手のホスト名を打ってください（%s）: ' "$host"
        read -r ans
        [ "$ans" = "$host" ] || die "やめました。何も流していません。"
    else
        die "手元以外へ流すには CONFIRM_LOADTEST=${host} が要ります。何も流していません。"
    fi
fi

# ── 手元なら、このプロジェクトの nginx かを確かめる ──
# 手元では別のスタック（別名で立てた検証用・デモなど）が別のポートで動いていることがある。
# ポートが違えば、**このプロジェクトではないサイトへ流す**ことになるので止める
if [ "$local_target" = 1 ]; then
    mine="$(docker compose port nginx 80 2>/dev/null | sed 's/.*://' || true)"
    want="${hostport##*:}"; [ "$want" = "$hostport" ] && want=80
    if [ "$mine" != "$want" ]; then
        if [ -z "$mine" ]; then
            log "注意: このプロジェクトの nginx が動いていません（docker compose ps）。${url} は別のスタックかもしれません。"
        else
            log "注意: このプロジェクトの nginx は :${mine} です。${url} は別のスタックです。"
        fi
        if [ "${CONFIRM_LOADTEST:-}" = "$hostport" ]; then
            :
        elif [ -t 0 ]; then
            printf '[loadtest] それでも流すなら、相手（%s）を打ってください: ' "$hostport"
            read -r ans
            [ "$ans" = "$hostport" ] || die "やめました。何も流していません。"
        else
            die "相手がこのプロジェクトの nginx ではありません。流すなら CONFIRM_LOADTEST=${hostport}。何も流していません。"
        fi
    fi
fi

# ── k6 のコンテナから相手へ届く形にする ──
# 手元の 127.0.0.1 は、コンテナの中から見ると自分自身。Linux は host のネットワークをそのまま使い、
# macOS / Windows（Docker Desktop）は host.docker.internal で外のホストを指す。
net_opts=(); target="$url"
if [ "$local_target" = 1 ]; then
    if [ "$(uname -s)" = Linux ]; then
        net_opts=(--network host)
    else
        target="${url/:\/\/${host}/://host.docker.internal}"
    fi
fi

stamp="$(date +%Y%m%d-%H%M%S)"
out="var/loadtest/${stamp}-${profile}"
mkdir -p "$out"

# 条件を残す（あとで「何を変えたら何が変わったか」を比べるため）
{
    echo "日時:         $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "相手:         ${url}"
    if [ "$profile" = smoke ]; then
        echo "流し方:       smoke（1 PV/秒・30 秒、cart ${cart_ratio}、p95 ${p95}ms）"
    else
        echo "流し方:       ${profile}（山 ${rate} PV/秒、保つ ${duration}、上り ${ramp}、cart ${cart_ratio}、p95 ${p95}ms）"
    fi
    echo "k6:           ${K6_IMAGE%@*}"
    echo "eccube-docker: $(cat VERSION 2>/dev/null || echo '?')（$(git rev-parse --short HEAD 2>/dev/null || echo 'git なし')）"
    if [ "$local_target" = 1 ]; then
        echo "イメージ:     $(image_ref)"
        echo "APP_ENV:      $(env_get APP_ENV)"
        echo "PROFILES:     $(env_get COMPOSE_PROFILES)"
        echo "php-fpm:      pm=$(env_get PHP_FPM_PM) max_children=$(env_get PHP_FPM_MAX_CHILDREN)"
        echo "CPU / メモリ: $(docker info --format '{{.NCPU}} CPU / {{.MemTotal}} bytes' 2>/dev/null || echo '?')（Docker から見える分）"
    fi
} > "$out/conditions.txt"
cat "$out/conditions.txt"

# ── 手元なら、流しているあいだのコンテナの CPU / メモリを 5 秒ごとに残す ──
sampler=""
if [ "$local_target" = 1 ] && [ -n "$(docker compose ps -q ec-cube 2>/dev/null)" ]; then
    ids="$(docker compose ps -q 2>/dev/null | tr '\n' ' ')"
    echo "時刻,コンテナ,CPU,メモリ" > "$out/docker-stats.csv"
    (
        while :; do
            t="$(date +%H:%M:%S)"
            # shellcheck disable=SC2086
            docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" $ids 2>/dev/null | sed "s/^/${t},/" >> "$out/docker-stats.csv" || true
            sleep 5
        done
    ) &
    sampler=$!
fi
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cleanup() {
    if [ -n "$sampler" ]; then
        kill "$sampler" 2>/dev/null || true
        wait "$sampler" 2>/dev/null || true   # 「Terminated」を出さない
    fi
}
trap cleanup EXIT

log "流します（結果: ${out}/）..."
set +e
docker run --rm -i ${net_opts[@]+"${net_opts[@]}"} \
    -v "$PWD/docker/k6:/scripts:ro" -v "$PWD/$out:/out" \
    -e BASE_URL="$target" -e PROFILE="$profile" -e RATE="$rate" -e DURATION="$duration" -e RAMP="$ramp" \
    -e CART_RATIO="$cart_ratio" -e P95_MS="$p95" ${max_vus:+-e MAX_VUS="$max_vus"} -e OUT_DIR=/out \
    "$K6_IMAGE" run --quiet /scripts/eccube.js
rc=$?
set -e
cleanup; sampler=""

# ── 手元なら、詰まりの手がかりを出す ──
if [ "$local_target" = 1 ] && [ -s "$out/docker-stats.csv" ]; then
    echo "コンテナごとの CPU の最大（100% = 1 コア）:"
    awk -F, 'NR > 1 { gsub(/%/, "", $3); if ($3 + 0 > max[$2]) max[$2] = $3 + 0 } END { for (k in max) printf "  %-32s %6.1f%%\n", k, max[k] }' "$out/docker-stats.csv" | sort
    # php-fpm の子プロセスが足りなくなると、ここに出る。出ていれば PHP_FPM_MAX_CHILDREN か台数が先
    n="$(docker compose logs --no-color --since "$started" ec-cube 2>/dev/null | grep -c 'max_children' || true)"
    if [ "${n:-0}" -gt 0 ]; then
        echo "php-fpm: 子プロセスが上限（max_children）に達した記録が ${n} 件。PHP の枠が先に詰まっています（docs/loadtest.md「読み方」）。"
    fi
fi
echo
case "$rc" in
    0)  log "終わりました。合格の線の内側です。結果: ${out}/" ;;
    99) log "終わりました。**合格の線を割りました**（上の「不合格」）。結果: ${out}/" ;;
    *)  log "k6 が止まりました（終了コード ${rc}）。結果: ${out}/" ;;
esac
exit "$rc"
