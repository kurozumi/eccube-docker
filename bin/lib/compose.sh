#!/usr/bin/env bash
# どのスクリプトも同じ compose ファイルの並びを使うための共通処理。
#
#   . "$(dirname "$0")/lib/compose.sh"
#   dc=(docker compose $(compose_files))          # 開発（override 込み）
#   dc=(docker compose $(compose_files --prod))   # 本番（override を外し prod を重ねる）
#
# なぜ要るか:
#   DB を PostgreSQL にすると compose.postgresql.yaml を重ねる必要があり、それは .env の
#   COMPOSE_FILE に入っている。ところが `docker compose -f a -f b` と直書きすると
#   **COMPOSE_FILE は無視される**（-f が勝つ）。以前 upgrade / publish / deploy が直書き
#   していたので、そのままだと**本番だけ MariaDB が立つ**。ここで .env の並びを読み、
#   prod の出し入れだけをする。
#
# .env に COMPOSE_FILE が無ければ compose の既定と同じ「compose.yaml + compose.override.yaml」。

# .env の COMPOSE_FILE（区切りは : ）。無ければ既定
compose_files_from_env() {
    local v
    v="$(grep -E '^COMPOSE_FILE=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    [ -n "$v" ] || v="compose.yaml:compose.override.yaml"
    printf '%s' "$v"
}

# -f の並びを出す。--prod で override を外して compose.prod.yaml を足す。
# **compose.app.yaml（複数ホストのアプリ層）には compose.prod.yaml を足さない。** app.yaml はそれだけで
# 本番の構成で、prod.yaml は db / cloudflared など app.yaml に無いサービスを指すため、重ねると
# 「service "db" has neither an image nor a build context」で compose ごと読めなくなる。
compose_files() { # compose_files [--prod]
    local prod=0 f out="" app=0
    [ "${1:-}" = "--prod" ] && prod=1
    IFS=':' read -r -a _files <<< "$(compose_files_from_env)"
    for f in "${_files[@]}"; do
        [ -n "$f" ] || continue
        if [ "$prod" = 1 ] && [ "$f" = "compose.override.yaml" ]; then continue; fi
        [ "$f" = "compose.prod.yaml" ] && continue
        [ "$f" = "compose.app.yaml" ] && app=1
        out="$out -f $f"
    done
    [ "$prod" = 1 ] && [ "$app" = 0 ] && out="$out -f compose.prod.yaml"
    printf '%s' "${out# }"
}

# nginx に手元から届く URL（http://host:port）。**HTTP_PORT から決め打ちしない。**
# 複数ホストでは HTTP_BIND=10.0.0.11 のように内側の IP だけで待ち受けるので、localhost では届かない
# （deploy.sh の疎通確認が必ず失敗し、メンテナンス表示のまま止まっていた）。同じ機械の別のスタックが
# 8080 を使っていると、よそのサイトを見てしまう（plugin.sh doctor で実際にあった）。
# compose に実際に開いている場所を聞き、0.0.0.0 / [::] は localhost に読み替える。
compose_nginx_url() { # compose_nginx_url [compose の引数…]（既定は docker compose）
    local p
    if [ "$#" -gt 0 ]; then p="$("$@" port nginx 80 2>/dev/null | tail -1 || true)"
    else p="$(docker compose port nginx 80 2>/dev/null | tail -1 || true)"; fi
    p="${p/0.0.0.0/localhost}"
    p="${p/\[::\]/localhost}"
    if [ -z "$p" ]; then
        p="$(grep -E '^HTTP_PORT=' .env 2>/dev/null | cut -d= -f2- || true)"
        p="localhost:${p:-8080}"
    fi
    printf 'http://%s' "$p"
}
