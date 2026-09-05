#!/usr/bin/env bash
# サーバーの管理画面で書かれたファイルを、手元の作業ツリーへ取り込む。
#
#   bin/pull-admin-files.sh shop:/srv/myshop
#
# 管理画面（CSS/JS 管理・メール設定の本文・ページ管理・ブロック管理）はサーバーの
# ディスクに書く。**そのファイルはサーバーにしか無い。** サーバーの bin/backup.sh には
# 入るが、git には誰かが入れない限り入らない。ここで手元に取り込み、commit → push で
# あなたのリポジトリに残す。以後は deploy で消えない。
#
# 取り込むのは app/template と html/user_data だけ（管理画面が書く場所）。
# **app/Plugin は取らない。** 手元のプラグインはそれぞれ git 管理で、上書きすると壊す。
set -euo pipefail
cd "$(dirname "$0")/.."

log() { echo "[pull-admin] $*"; }
die() { echo "[pull-admin] エラー: $*" >&2; exit 1; }

remote="${1:-}"
[ -n "$remote" ] || die "使い方: bin/pull-admin-files.sh host:/path   例: shop:/srv/myshop"
host="${remote%%:*}"; path="${remote#*:}"
[ "$host" != "$remote" ] && [ -n "$path" ] || die "host:/path の形で指定してください"

# 手元で**変更した追跡ファイル**があれば止める。取り込みで上書きして失う。
# 未追跡（??）は止めない。管理画面で作ったページを手元にも置いている、という普通の
# 状態で毎回止まってしまう（実際にそうなった）。上書きされうる旨だけ出す。
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    st="$(git status --porcelain -- app/template html/user_data 2>/dev/null || true)"
    modified="$(printf '%s\n' "$st" | grep -E '^( M|M |MM|AM| D|D )' || true)"
    untracked="$(printf '%s\n' "$st" | grep -E '^\?\?' || true)"
    if [ -n "$modified" ]; then
        printf '%s\n' "$modified" | sed 's/^/    /' >&2
        die "手元の app/template / html/user_data に未コミットの変更があります。先に commit するか stash してください。"
    fi
    if [ -n "$untracked" ]; then
        log "注意: 手元に未追跡のファイルがあります。サーバーに同じパスがあれば上書きされます:"
        printf '%s\n' "$untracked" | sed 's/^/    /'
    fi
fi

log "${host} の ${path} から app/template と html/user_data を取り込みます..."
# tar で 1 本にして流す。ファイル単位の scp は遅く、途中で切れたときに半端が残る。
ssh "$host" "cd '${path}' && tar -czf - app/template html/user_data" | tar -xzf -

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    changed="$(git status --porcelain -- app/template html/user_data 2>/dev/null || true)"
    if [ -z "$changed" ]; then
        log "手元と同じでした。取り込むものはありません。"
        exit 0
    fi
    log "取り込みました。手元に無かった・違っていたもの:"
    printf '%s\n' "$changed" | sed 's/^/    /'
    echo
    log "内容を確かめて、あなたのリポジトリに残してください:"
    log "    git add app/template html/user_data"
    log "    git commit -m \"管理画面で直した分を取り込む\" && git push"
else
    log "取り込みました（git 管理外なので差分は出せません）。"
fi
