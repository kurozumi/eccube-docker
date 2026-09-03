#!/usr/bin/env bash
# 破壊的な操作の前に確認するための共通処理。
#
# **本番で `down -v` を打つと DB と画像が消え、その場では戻せない。**
# 頼りはバックアップだけになる。そこで、稼働中のスタックが本番構成なら
# 対話の確認では通さず、プロジェクト名の入力を求める。
#
#   source "$(dirname "$0")/lib/guard.sh"
#   guard_destructive reset "DB とアップロード画像"

# compose のプロジェクト名。COMPOSE_PROJECT_NAME や compose.yaml の name: を
# compose 自身に解決させる。
guard_project_name() {
    docker compose config --format json 2>/dev/null |
        sed -n 's/^  "name": "\(.*\)",$/\1/p' | head -1
}

# 稼働中のスタックが本番構成か。
#
# **稼働中のコンテナのラベルを見る。** compose は起動に使ったファイルの一覧を
# com.docker.compose.project.config_files に残す。`docker compose ls` の JSON は
# 並び順に依存する読み方になるので使わない。
#
# 止まっているときは判定できない。**判定できないことを「本番ではない」と
# 扱わない**よう、呼び出し側で戻り値 2 を別に扱えるようにしてある。
#   0 … 本番構成で動いている
#   1 … 本番構成ではない
#   2 … 判定できない（停止中）
guard_is_prod_stack() {
    local cid cfg
    cid="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"

    [ -n "$cid" ] || return 2

    cfg="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
        "$cid" 2>/dev/null || true)"

    case "$cfg" in
        *compose.prod.yaml*) return 0 ;;
        *) return 1 ;;
    esac
}

# 破壊的な操作の前に確認する。通らなければ終了する。
#   $1 … ログの接頭辞。**スクリプト名に合わせる**（案内文に使うため）
#   $2 … 何が消えるかの説明
guard_destructive() {
    local tag="$1" what="$2" proj
    proj="$(guard_project_name)"

    echo "[${tag}] ${what}を削除します。**元に戻せません。**"
    echo "[${tag}] 残したいものがあれば、先に bin/backup.sh を実行してください。"

    guard_is_prod_stack
    local prod=$?

    if [ "$prod" = "0" ]; then
        echo "[${tag}] エラー: 稼働中のスタックは**本番構成**です（compose.prod.yaml）。" >&2
        echo "[${tag}] 本番のデータを消そうとしています。" >&2
        echo >&2
        echo "  本当に消すなら、プロジェクト名を渡して実行してください:" >&2
        echo "    CONFIRM_DESTROY=${proj} bin/${tag}" >&2  # 例: bin/reset.sh / bin/switch-version.sh
        echo >&2
        echo "  上げ直したいだけなら bin/upgrade.sh <制約> --prod を使ってください" >&2
        echo "  （こちらは DB と画像を残します）。" >&2

        if [ "${CONFIRM_DESTROY:-}" != "$proj" ]; then
            exit 1
        fi

        echo "[${tag}] CONFIRM_DESTROY を確認しました。続行します。"

        return 0
    fi

    # 停止中は本番かどうか分からない。**分からないことを黙って通さない。**
    if [ "$prod" = "2" ]; then
        echo "[${tag}] 注意: コンテナが停止しているため、本番構成かどうか判定できません。"
        echo "[${tag}]       本番のサーバーで実行していないか、もう一度確かめてください。"
    fi

    read -r -p "続行しますか? [y/N] " ans
    [ "$ans" = "y" ] || { echo "中止しました"; exit 1; }
}
