#!/usr/bin/env bash
# 本番構成で起動する（compose.prod.yaml を使用）。
# 公開方式は .env の COMPOSE_PROFILES で選ぶ（tunnel / caddy / 空=背後配置）。
set -euo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"
# shellcheck source=lib/compose.sh
. "$(dirname "$0")/lib/compose.sh"

# ── シークレットが既定値のまま本番公開するのを防ぐガード ──
# どうしても既定値のまま起動したい場合のみ FORCE_PUBLISH=1 bin/publish.sh
if [ "${FORCE_PUBLISH:-0}" != "1" ] && [ -f .env ]; then
    bad=0
    for pair in \
        "ECCUBE_AUTH_MAGIC=change_this_to_a_random_hex_string" \
        "DB_PASSWORD=eccube_pass" \
        "DB_ROOT_PASSWORD=change_me_root"; do
        if grep -qE "^${pair}$" .env; then
            echo "[publish] エラー: ${pair%%=*} が既定値のままです。"
            bad=1
        fi
    done
    # メール送信（注文メール・会員登録・パスワード再発行）。本番で未設定だと null://null で
    # **黙って破棄**され、開発の Mailpit 宛てだと本番には居ないホストへ送って失敗する。どちらも
    # 画面は正常に見えるので気づけない。実メールサービスの DSN を .env に書く。
    mail="$(grep -E '^MAILER_DSN=' .env | head -1 | cut -d= -f2- || true)"
    case "$mail" in
        "")          echo "[publish] エラー: MAILER_DSN が .env にありません。本番では注文メール等が黙って破棄されます。"; bad=1 ;;
        null://*)    echo "[publish] エラー: MAILER_DSN が null:// です。本番では注文メール等が黙って破棄されます。"; bad=1 ;;
        *mailpit*)   echo "[publish] エラー: MAILER_DSN が開発用の Mailpit を指しています。本番には居ないので送信が失敗します。"; bad=1 ;;
    esac
    if [ "$bad" = "1" ]; then
        echo "[publish] 本番公開を中止しました。.env のシークレットを固有の値にし、MAILER_DSN に実メールサービスを書いてください。"
        echo "          例: MAILER_DSN=smtp://user:pass@smtp.example.com:587（docs/deploy.md「メール送信」）"
        echo "          （新規環境なら rm .env && bin/init.sh で自動生成されます。"
        echo "            既定値で DB 初期化済みの場合はデータ再作成が必要: docker compose down -v）"
        echo "          それでも起動する場合: FORCE_PUBLISH=1 bin/publish.sh"
        exit 1
    fi
fi

# shellcheck disable=SC2046
dc=(docker compose $(compose_files --prod))

# 配布イメージなら pull、そうでなければ build。**`up -d --build` と書かない。**
if ! image_provision "${dc[@]}"; then
    echo "[publish] エラー: イメージを用意できませんでした。公開していません。" >&2
    exit 1
fi

# ── 初期管理者が admin / password のままなら公開しない（#108）──
# .env の ECCUBE_ADMIN_PASS はインストールの瞬間にしか効かないので、いまの DB を見る。
# DB だけ先に上げ、使い捨てのコンテナで判定してから公開層を含む全体を起動する
# （全部上げてから判定すると、止めた時点でもう公開されている）。判定スクリプトは
# 標準入力で php に渡す（イメージに焼かない。配布済みの古いイメージでも動くように）。
if [ "${FORCE_PUBLISH:-0}" != "1" ] && "${dc[@]}" config --services 2>/dev/null | grep -qx db; then
    "${dc[@]}" up -d --wait db >/dev/null 2>&1 || true
    verdict="$("${dc[@]}" run --rm --no-deps -T --entrypoint php ec-cube < "$(dirname "$0")/lib/admin-password-check.php" 2>/dev/null | tail -1 || true)"
    case "$verdict" in
        DEFAULT)
            echo "[publish] エラー: 管理者 admin のパスワードが既定の「password」のままです。公開を中止しました。" >&2
            echo "          管理画面 → 設定 → システム設定 → メンバー管理 で変えてから、もう一度実行してください。" >&2
            echo "          （新規環境なら .env の ECCUBE_ADMIN_PASS を変えて docker compose down -v で作り直し）" >&2
            echo "          それでも公開する場合: FORCE_PUBLISH=1 bin/publish.sh" >&2
            exit 1 ;;
        OK)   echo "[publish] 管理者パスワード: 既定値ではない" ;;
        *)    echo "[publish] 管理者パスワード: 判定できませんでした（未インストールなら install 時に .env の ECCUBE_ADMIN_PASS が使われます）" ;;
    esac
fi

"${dc[@]}" up -d
"${dc[@]}" ps
