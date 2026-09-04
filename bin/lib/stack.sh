#!/usr/bin/env bash
# 「どのスタックに繋がっているか」を確かめるための共通処理。
#
# **プロジェクト名がずれていると、直したつもりで直らない。** compose は
# COMPOSE_PROJECT_NAME か compose.yaml の `name:` でスタックを決めるので、
# 別名で起動していたり、別のクローンから打っていたりすると、止まっている
# ほうのスタックへ行く。素の compose は
#
#   service "ec-cube" is not running
#
# としか言わないので、**どこで動いているのか**が分からない。ここでそれを出す。
#
#   source "$(dirname "$0")/lib/stack.sh"
#   stack_require_running ec-cube console || exit 1

# いま動いているスタックのうち、指定したサービスを持つものを列挙する。
# 出力は「プロジェクト名<TAB>起動に使った compose ファイル」。
stack_running_projects() {
    local service="$1"
    docker ps \
        --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.service"}}	{{.Label "com.docker.compose.project.config_files"}}' \
        2>/dev/null |
        awk -F'\t' -v s="$service" '$2 == s { print $1 "\t" $3 }' |
        sort -u
}

# 指定したサービスが「このスタックで」動いているか。
# 動いていなければ、どこで動いているかまで出す。
#   $1 … サービス名
#   $2 … ログの接頭辞
# 戻り値: 0 = 動いている / 1 = 動いていない
stack_require_running() {
    local service="$1" tag="$2" proj others

    if [ -n "$(docker compose ps -q "$service" 2>/dev/null)" ]; then
        return 0
    fi

    proj="$(docker compose config --format json 2>/dev/null |
        sed -n 's/^  "name": "\(.*\)",$/\1/p' | head -1)"

    echo "[${tag}] ${service} が起動していません（プロジェクト名: ${proj:-不明}）。" >&2

    others="$(stack_running_projects "$service")"

    # **別のスタックで動いているなら、それがほぼ原因。**
    if [ -n "$others" ]; then
        echo >&2
        echo "  いま ${service} が動いているのは別のスタックです:" >&2
        echo >&2
        printf '    %s\n' "$others" | expand -t 4 >&2
        echo >&2
        echo "  同じ compose ファイルなら、.env に名前を書いて固定してください:" >&2
        echo "    COMPOSE_PROJECT_NAME=$(printf '%s' "$others" | head -1 | cut -f1)" >&2
        echo >&2
        echo "  別のディレクトリのものなら、そちらで実行してください" >&2
        echo "  （bin/*.sh はスクリプト自身の置き場所を見ます）。" >&2
    else
        echo >&2
        echo "  どのスタックでも動いていません。起動してください:" >&2
        echo "    docker compose up -d" >&2
    fi

    return 1
}
