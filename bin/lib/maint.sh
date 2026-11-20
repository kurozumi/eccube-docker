# shellcheck shell=bash
# メンテナンス表示まわりの共通の処理（deploy.sh / restore.sh / upgrade.sh / setup.sh が読む）。

# maint_drain <compose を呼ぶコマンド…>
#   メンテナンス表示を立てた**あと**（自分で立てたものでも、手で入れてあったものでも）、立てる前に受け付けた
#   要求（注文の確定など）が終わるのを待つ。表示は新しい要求を止めるだけで、処理中のものは止めない。
#   そのまま DB を取ると、ダンプが始まったあとに確定した注文がダンプに入らず、そのダンプから戻すと消える。
#   **動いている ec-cube の全部の複製**（--scale）の php-fpm の状態ページで処理中の数を見て、どれも
#   自分（状態ページへの問い合わせ）だけになるまで待つ（全体で最大 30 秒。1 回の問い合わせは 3 秒まで）。
#   0 … 待てた（動いている ec-cube が無いときも 0）。
#   1 … 30 秒たっても残っている（ログイン中の管理者は表示を素通りするので、ありうる）か、数を読めなかった。
#       呼んだ側は注意を出して進む（止めると、管理者がいる限り何もできなくなる）。
#   例: maint_drain docker compose -f compose.yaml -f compose.prod.yaml
maint_drain() {
    local deadline ids id n busy
    deadline=$(( $(date +%s) + 30 ))
    ids="$("$@" ps -q --status running ec-cube 2>/dev/null || true)"
    [ -n "$ids" ] || return 0
    while :; do
        busy=0
        for id in $ids; do
            n="$(docker exec "$id" sh -c 'SCRIPT_NAME=/fpm-status SCRIPT_FILENAME=/fpm-status QUERY_STRING= REQUEST_METHOD=GET timeout 3 cgi-fcgi -bind -connect 127.0.0.1:9000 2>/dev/null | sed -n "s/^active processes: *//p"' 2>/dev/null | tr -d '\r' || true)"
            case "$n" in '' | *[!0-9]*) return 1 ;; esac
            [ "$n" -le 1 ] || busy=1
        done
        [ "$busy" = 0 ] && return 0
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 1
    done
}
