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

# -f の並びを出す。--prod で override を外して compose.prod.yaml を足す
compose_files() { # compose_files [--prod]
    local prod=0 f out=""
    [ "${1:-}" = "--prod" ] && prod=1
    IFS=':' read -r -a _files <<< "$(compose_files_from_env)"
    for f in "${_files[@]}"; do
        [ -n "$f" ] || continue
        if [ "$prod" = 1 ] && [ "$f" = "compose.override.yaml" ]; then continue; fi
        [ "$f" = "compose.prod.yaml" ] && continue
        out="$out -f $f"
    done
    [ "$prod" = 1 ] && out="$out -f compose.prod.yaml"
    printf '%s' "${out# }"
}
