#!/usr/bin/env bash
# 借りたばかりのサーバーを、公開の一歩手前まで整える。**サーバーに git も GitHub の鍵も要らない。**
#   使い方: bin/bootstrap-server.sh <user>@<host> [/srv/myshop]
#
# やること（手元から ssh で）:
#   1. Docker が無ければ入れる（Ubuntu / Debian。get.docker.com の手順。sudo が使えること）
#   2. この店のファイル（git が追跡しているもの）を rsync で送る
#   3. 向こうで bin/init.sh --no-start（.env を作り、パスワード類を生成。起動はしない）
#      手元の .env に ECCUBE_IMAGE があれば向こうにも書く（サーバーで build しないで済む）
#   4. 次にやること（メール設定・Tunnel・公開）を表示する
#
# 以後の反映は bin/deploy.sh --remote=<user>@<host>:/srv/myshop（サーバーに .git が無いので手元から送る）。
set -euo pipefail
case "${1:-}" in -h|--help|"") awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
host="$1"; path="${2:-/srv/myshop}"
log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap] エラー: %s\n' "$*" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "この場所が git のリポジトリではありません（送るのは git が追跡しているファイルです）"
command -v rsync >/dev/null 2>&1 || die "rsync が必要です"
log "${host} に入れるか確かめます..."
ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" true 2>/dev/null || ssh -o ConnectTimeout=10 "$host" true || die "${host} に入れません。VPS の管理画面で SSH 鍵を登録したか、user@host が合っているか確認してください"
log "Docker を確かめます..."
ssh "$host" 'bash -s' <<'REMOTE'
set -e
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "  Docker あり: $(docker --version | cut -d, -f1) / compose $(docker compose version --short)"
else
    echo "  Docker が無いので入れます（数分）..."
    if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO="sudo"; fi
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && $SUDO sh /tmp/get-docker.sh >/dev/null && rm -f /tmp/get-docker.sh
    if [ "$(id -u)" != 0 ]; then $SUDO usermod -aG docker "$USER"; echo "  $USER を docker グループに入れました（次の ssh から効きます）"; fi
    echo "  入れました: $(docker --version | cut -d, -f1)"
fi
REMOTE
log "${host}:${path} へ店のファイルを送ります..."
ssh "$host" "mkdir -p '${path}'" 2>/dev/null || ssh "$host" "sudo mkdir -p '${path}' && sudo chown \"\$(id -u):\$(id -g)\" '${path}'" || die "${path} を作れません"
git ls-files -z | rsync -az --from0 --files-from=- ./ "${host}:${path}/" || die "送れませんでした"
img="$(grep -E '^ECCUBE_IMAGE=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
log "向こうで .env を作ります（パスワード類を生成。起動はしません）..."
ssh "$host" "cd '${path}' && bin/init.sh --no-start" | sed 's/^/  /'
if [ -n "$img" ]; then
    ssh "$host" "cd '${path}' && (grep -qE '^#?ECCUBE_IMAGE=' .env && sed -i \"s|^#\\{0,1\\}ECCUBE_IMAGE=.*|ECCUBE_IMAGE=${img}|\" .env || echo 'ECCUBE_IMAGE=${img}' >> .env)"
    log "ECCUBE_IMAGE=${img} を向こうの .env に書きました（配布イメージを pull するだけで済みます）"
else
    log "注意: 手元の .env に ECCUBE_IMAGE が無いので、向こうは build します（10 分以上）。docs/install.md のタグ表を見て向こうの .env に書くと速い"
fi
cat <<EOS

[bootstrap] できました。次にやること（順番に。全部この手元から打てます）:

  1. メール送信の設定（質問に答えて 1 通試す）
       bin/setup.sh mail --remote=${host}:${path}
  2. ドメインと HTTPS（Cloudflare Tunnel。トークンを貼ると、繋がるか試してから書く）
       bin/setup.sh tunnel --remote=${host}:${path}
  3. 公開する
       bin/publish.sh --remote=${host}:${path}
  4. バックアップの送り先と毎日の自動実行
       bin/setup.sh backup --remote=${host}:${path}
  以後、直したら:
       bin/deploy.sh --remote=${host}:${path}
EOS
