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
# **compose.app.yaml（複数ホストのアプリ層）も本番として扱う。** あれは LB の後ろに並べる本番専用の
# 構成で、compose.prod.yaml を重ねない。以前は prod.yaml だけを見ていたので、アプリホストは「本番では
# ない」と判定され、deploy.sh の main 以外を止める守りもプロジェクト名の確認も素通りしていた。
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
# .env（または環境変数）の COMPOSE_FILE に compose.app.yaml が入っているか。
# deploy.sh は向こうのサーバーで guard.sh だけを読むので、compose.sh に頼らない
_guard_app_role() {
    local f="${COMPOSE_FILE:-}"
    [ -n "$f" ] || f="$(sed -n 's/^COMPOSE_FILE=//p' .env 2>/dev/null | tail -1 | tr -d "\"'")"
    case ":${f}:" in *:compose.app.yaml:*) return 0 ;; esac
    return 1
}

guard_is_prod_stack() {
    local cid cfg
    cid="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"

    # **止まっていても、アプリホスト（compose.app.yaml）なら本番と分かる。** .env の並びは動いていなくても読める。
    # 上げる手順ではアプリホストをわざと止めるので、ここを「判定できない」にすると reset.sh が y だけで通っていた
    [ -n "$cid" ] || { _guard_app_role && return 0; return 2; }

    cfg="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
        "$cid" 2>/dev/null || true)"

    case "$cfg" in
        *compose.prod.yaml*|*compose.app.yaml*) return 0 ;;
        *) return 1 ;;
    esac
}

# 破壊的な操作の前に確認する。通らなければ終了する。
#   $1 … ログの接頭辞。**スクリプト名に合わせる**（案内文に使うため）
#   $2 … 何が消えるかの説明
guard_destructive() {
    local tag="$1" what="$2" proj
    proj="$(guard_project_name)"

    echo "[${tag}] ${what}を削除します。"
    echo "[${tag}] 消す前に backups/<日時>-before-<名前>/ へ退避します（取れなければ何も消さずに止まります）。"

    # **戻り値は `|| prod=$?` で受ける。** 呼び出し側（switch-version.sh / reset.sh）は
    # set -e で動いている。素で呼ぶと、本番でない（1）・停止中（2）を返した時点で
    # スクリプトごと終わり、確認の質問にすら辿り着かない（開発環境で実際にそうなった）。
    local prod=0
    guard_is_prod_stack || prod=$?

    if [ "$prod" = "0" ]; then
        echo "[${tag}] エラー: このスタックは**本番構成**です（compose.prod.yaml / compose.app.yaml）。" >&2
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

# 消す直前に、いまの DB・画像・ファイルを backups/<日時>-before-<名前>/ へ取る。取れなければ止める。
#   guard_backup_before_destroy <名前（英小文字・数字・-）>
# **このプロジェクトのボリュームが 1 つも無ければ取らない**（消えるものが無い）。止まっているスタックでは DB に繋がらず
# 取れないので、そのときは「db を起こしてから」と言って止める。取らずに消すのは
# DESTROY_WITHOUT_BACKUP=<プロジェクト名> のときだけ。
guard_backup_before_destroy() {
    local label="$1" proj vols
    proj="$(guard_project_name)"
    # **このプロジェクトのボリュームが 1 つでもあれば取る。** DB のボリュームだけを見ていると、外部 DB の店
    # （compose.externaldb.yaml・compose.app.yaml。手元に DB のボリュームが無い）で「消えるものが無い」と
    # 判断し、画像（eccube_upload）を退避なしで消していた
    # 一覧が取れなかったことを「ボリューム無し」と取り違えない（取り違えると退避を飛ばし、そのあと消す）
    if ! vols="$(docker volume ls -q --filter "label=com.docker.compose.project=${proj}")"; then
        echo "[${label}] エラー: ボリュームの一覧を取れませんでした（Docker が応答しない？）。**何も消していません。**" >&2
        exit 1
    fi
    if [ -z "$vols" ]; then
        echo "[${label}] このプロジェクト（${proj}）のボリュームがまだ無いので、退避は取りません。"
        return 0
    fi
    if [ -n "${DESTROY_WITHOUT_BACKUP:-}" ]; then
        [ "$DESTROY_WITHOUT_BACKUP" = "$proj" ] || { echo "[${label}] エラー: DESTROY_WITHOUT_BACKUP がプロジェクト名（${proj}）と違います。何も消していません。" >&2; exit 1; }
        echo "[${label}] 注意: DESTROY_WITHOUT_BACKUP が付いているので、退避を取らずに消します。"
        return 0
    fi
    echo "[${label}] 消す前に、いまの DB・画像・管理画面が書いたファイルを退避します..."
    local rf
    rf="$(mktemp)"
    if ! BACKUP_LABEL="$label" BACKUP_RESULT_FILE="$rf" bin/backup.sh >"${rf}.log" 2>&1; then
        tail -5 "${rf}.log" >&2; rm -f "$rf" "${rf}.log"
        cat >&2 <<EOS
[${label}] エラー: 退避を取れませんでした。**何も消していません。**
  止まっているなら DB を起こしてから、もう一度: docker compose up -d db
  消えてよいと分かっているときだけ: DESTROY_WITHOUT_BACKUP=${proj} bin/${label}.sh
EOS
        exit 1
    fi
    echo "[${label}] 退避しました: $(cat "$rf")（戻すなら bin/restore.sh $(cat "$rf")）"
    rm -f "$rf" "${rf}.log"
}

