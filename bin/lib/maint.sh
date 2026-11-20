# shellcheck shell=bash
# メンテナンス表示まわりの共通の処理（deploy.sh / restore.sh / upgrade.sh / setup.sh が読む）。

# maint_drain <compose を呼ぶコマンド…>
#   メンテナンス表示を立てた**あと**、立てる前に受け付けた要求（注文の確定など）が終わるのを待つ。
#   表示は新しい要求を止めるだけで、処理中のものは止めない。そのまま DB を取ると、ダンプが始まったあとに
#   確定した注文がダンプに入らず、そのダンプから戻すと消える。php-fpm の状態ページで処理中の数を見て、
#   自分（状態ページへの問い合わせ）だけになるまで待つ（最大 30 秒）。
#   0 … 待てた。1 … 30 秒たっても残っている（ログイン中の管理者は表示を素通りするので、ありうる）か、
#   数を読めなかった。呼んだ側は注意を出して進む（止めると、管理者がいる限り何もできなくなる）。
#   例: maint_drain docker compose -f compose.yaml -f compose.prod.yaml
maint_drain() {
    local n
    for _ in $(seq 1 30); do
        n="$("$@" exec -T ec-cube sh -c 'SCRIPT_NAME=/fpm-status SCRIPT_FILENAME=/fpm-status QUERY_STRING= REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 2>/dev/null | sed -n "s/^active processes: *//p"' 2>/dev/null | tr -d '\r' || true)"
        case "$n" in '' | *[!0-9]*) return 1 ;; esac
        [ "$n" -le 1 ] && return 0
        sleep 1
    done
    return 1
}
