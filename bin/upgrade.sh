#!/usr/bin/env bash
# EC-CUBE を「データを保ったまま」新しいバージョンへ上げる。
#   使い方: bin/upgrade.sh ~4.3.2              （4.4 系は正式版がまだ無いので 4.4.0-alpha-1 か 4.4.x-dev）
#           bin/upgrade.sh 4.4.x-dev --php=8.5  PHP も一緒に変える（系列が対応している版だけ。
#                                                 指定しなければ、いまの PHP が使える限りそのまま）
#
# bin/switch-version.sh との違い:
#   switch-version.sh … down -v で DB・画像ごと破棄して作り直す（開発で別バージョンを試す用）
#   upgrade.sh        … DB(db_data) と画像(eccube_upload) は残し、本体コードだけ差し替えて
#                       未適用 migration を適用する（運用中の環境を上げる用）
#
# 仕組み（重要）:
#   eccube_app ボリュームが /var/www/html 全体を覆っているため、イメージを作り直しても
#   既存ボリュームが残っている限り新しい本体コードは反映されない（docker/php/
#   docker-entrypoint.sh の 1b) のコメント参照）。そこで eccube_app *だけ* 作り直し、
#   db_data と eccube_upload はそのまま残す。
#   ただし作り直した直後は var/.eccube_installed が消えるため、entrypoint が
#   「未インストール」と誤判定して既存 DB に eccube:install を撃ってしまう。
#   これを避けるため、起動前にマーカーだけ先に置いて migration 経路へ寄せる。
#   さらに、スキーマ（DDL）とデータ移行は別経路なので両方を流す（詳細は下の 7)）。
#
# **失敗したら、自動で元の版に戻す。** 止める前に .env をそのまま写し（var/upgrade/env.before）、
# メンテナンス表示の中でバックアップを取り（backups/<日時>-before-upgrade/）、本体ボリュームを
# <プロジェクト>_eccube_app_before_upgrade へ写してから入れ替える。途中で失敗したら、.env・イメージの
# タグ・本体ボリュームを戻し、DB に手を付けていればバックアップから戻して、元の版で起動し直す。
# 公開前の確認もメンテナンス表示の中でするので、確認が通るまでお客さんは注文できない
# （戻したときに、その間の注文が消えることがない）。
set -Eeuo pipefail
# -h / --help は先頭のコメント（この説明）をそのまま出す。AI や初めての人が最初に打つのはこれ
case "${1:-}" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/.."
# shellcheck source=lib/image.sh
. "$(dirname "$0")/lib/image.sh"
# shellcheck source=lib/compose.sh
. "$(dirname "$0")/lib/compose.sh"
# shellcheck source=lib/maint.sh
. "$(dirname "$0")/lib/maint.sh"

# --prod は本番構成（compose.prod.yaml）で上げる指定。位置は問わない。
# --php=8.x は PHP も一緒に変える指定。
want_prod=0
want_php=""
args=()
for a in "$@"; do
    case "$a" in
        --prod)  want_prod=1 ;;
        --php=*) want_php="${a#--php=}" ;;
        --php)   echo "エラー: --php=8.3 の形で指定してください。" >&2; exit 1 ;;
        *)       args+=("$a") ;;
    esac
done
set -- ${args[@]+"${args[@]}"}

ver="${1:-}"
if [ -z "$ver" ]; then
    echo "使い方: bin/upgrade.sh <制約> [--prod] [--php=<版>]   例: ~4.3.2 / 4.4.x-dev --php=8.5"
    echo "  データを保ったままバージョンを上げます。"
    echo "  データごと作り直したい場合は bin/switch-version.sh を使ってください。"
    exit 1
fi

# **.env を書き換える前に**、その制約が本当に解決できるか確かめる（~4.4.0 のような指定で
# 数分 build してから composer が落ちる、を避ける）
image_check_version "$ver" "bin/upgrade.sh$([ "$want_prod" = 1 ] && printf ' --prod')" || exit 1
current="$(grep -E '^ECCUBE_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
current_redis="$(grep -E '^PHPREDIS_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
current_image="$(env_get ECCUBE_IMAGE)"
series="$(image_series "$ver")"

# phpredis は EC-CUBE 側の Symfony Cache に合わせる必要があり、両立しない
# （4.2/4.3 は 6.0.2、4.4 は 6.3.0。対応表は bin/lib/image.sh）。
# **ここが無いと、系列をまたぐ upgrade で古い phpredis のままビルドされる。**
# switch-version.sh は以前からこれをやっているが、マイナーをまたぐのは
# 運用中の環境を上げる upgrade.sh の方なので、影響はこちらの方が大きい。
redis_ver="$(image_phpredis_for_series "$series")"

# PHP。**.env を書き換える前に**、上げた先の系列で使えるかを確かめる（使えない版で数分 build して
# から落ちる、配布イメージなら存在しないタグを pull して落ちる、を避ける）。
# いまの PHP は動いているイメージから読む（.env の PHP_VERSION は build にしか使われず、
# 配布イメージではタグが正なので、どちらも実物とずれうる）。
current_php="$(grep -E '^PHP_VERSION=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
cid_now="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"
running_php=""
[ -n "$cid_now" ] && running_php="$(image_php_of_container "$cid_now")"
# 実物を先に見る。配布イメージの -php 無しの固定タグ（4.3-v1.0.12）は、タグからは PHP が分からない
if [ -n "$running_php" ]; then
    base_php="$running_php"
elif [ -n "$current_image" ] && image_uses_registry; then
    # 固定の短いタグはタグから読めない（空）。そのときは .env の値（無ければ既定へ寄る）
    base_php="$(image_ref_php "$current_image")"
    base_php="${base_php:-$current_php}"
else
    base_php="$current_php"
fi
php_ver="$(image_resolve_php "$series" "$want_php" "$base_php")" || exit 1

# compose のプロジェクト名（ボリューム名の接頭辞）。COMPOSE_PROJECT_NAME や
# compose.yaml の name: を compose 自身に解決させる。
proj="$(docker compose config --format json | sed -n 's/^  "name": "\(.*\)",$/\1/p' | head -1)"
if [ -z "$proj" ]; then
    echo "エラー: compose のプロジェクト名を取得できませんでした。" >&2
    exit 1
fi
app_vol="${proj}_eccube_app"
# DB ボリュームは種類で名前が違う（MariaDB: db_data / PostgreSQL: pg_data、compose.postgresql.yaml）
case "$(grep -E '^DB_ENGINE=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')" in
    postgresql) db_vol="${proj}_pg_data" ;;
    *)          db_vol="${proj}_db_data" ;;
esac

# 本番構成で起動するかどうか。**ここを外すと本番が開発構成で上がる。**
# publish.sh は compose.prod.yaml を重ねて起動するが、このスクリプトが素の
# `docker compose` を使うと compose.override.yaml（開発用のポートと bind mount）が
# 効いた状態で公開されてしまう。**画面は出るので気づきにくい。**
#
# --prod が無くても、いま動いているスタックが本番構成なら本番構成のまま上げる。
# 本番のサーバーで打つときに付け忘れても事故らないようにするため。
# shellcheck disable=SC2046
dc=(docker compose $(compose_files))

# **稼働中のコンテナのラベルを見る。** compose は起動に使ったファイルの一覧を
# com.docker.compose.project.config_files に残す。`docker compose ls` の JSON は
# 並び順に依存する読み方になるので使わない。
if [ "$want_prod" = "0" ]; then
    running_cid="$(docker compose ps -q ec-cube 2>/dev/null | head -1 || true)"

    if [ -n "$running_cid" ]; then
        cfg="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
            "$running_cid" 2>/dev/null || true)"

        case "$cfg" in
            *compose.prod.yaml*|*compose.app.yaml*)
                want_prod=1
                echo "[upgrade] 稼働中のスタックが本番構成なので、本番構成のまま上げます。"
                ;;
        esac
    fi
fi

if [ "$want_prod" = "1" ]; then
    # shellcheck disable=SC2207
    dc=(docker compose $(compose_files --prod))
fi

# ec-cube サービスのイメージ名（事前確認で compose を介さず直接起動するのに使う）。
# `config --images ec-cube` はサービス指定を無視して全イメージを返すので使わない。
image="$(docker compose config 2>/dev/null |
    awk '/^  ec-cube:$/{b=1;next} b&&/^  [a-zA-Z_-]+:$/{b=0} b&&/^    image:/{sub(/^    image: */,"");print;exit}')"
if [ -z "$image" ]; then
    echo "エラー: ec-cube のイメージ名を取得できませんでした。" >&2
    exit 1
fi

# 切り戻しに使う「いまのイメージ」。pull / build で同じタグが新しいものを指すようになる前に ID を控える。
# 動いているならそのコンテナのイメージ（タグが先に動いていても、実際に動いているもの）。
old_image_ref="$image"
old_image_id=""
[ -n "$cid_now" ] && old_image_id="$(docker inspect --format '{{.Image}}' "$cid_now" 2>/dev/null || true)"
[ -n "$old_image_id" ] || old_image_id="$(docker image inspect --format '{{.Id}}' "$old_image_ref" 2>/dev/null || true)"

# **前回の切り戻しが最後までいかなかったら、始めない。** 始めると、上げる前の本体の写し
# （${app_vol}_before_upgrade。本体・vendor・コンテナ内 .env の唯一の残り）を、いまの壊れた本体で上書きする。
if [ -f var/upgrade/rollback-failed ]; then
    cat >&2 <<EOS
エラー: 前回の bin/upgrade.sh の切り戻しが、最後までできていません（var/upgrade/rollback-failed）。
       上げる前の本体の写し（${app_vol}_before_upgrade）を上書きしないよう、始めません。
       そのときの表示に従って元に戻し、開くことを確かめてから、この印を消してください:
         rm var/upgrade/rollback-failed
EOS
    exit 1
fi

# 手元に db サービスがあるか（外部 DB・複数ホストのアプリホストには無い）
services_now="$("${dc[@]}" config --services 2>/dev/null || true)"
has_local_db=0; printf '%s\n' "$services_now" | grep -qx db && has_local_db=1
# DB ボリュームが無い＝まだ 1 度も構築していない。upgrade ではなく init の出番。
# **外部 DB の環境では見ない**（手元に DB のボリュームが無いのが正しい。以前はアプリホストで必ず止まっていた）
if [ "$has_local_db" = 1 ] && ! docker volume inspect "$db_vol" >/dev/null 2>&1; then
    echo "エラー: DB ボリューム（${db_vol}）がありません。まだ構築されていない環境です。" >&2
    echo "       初回セットアップは bin/init.sh を使ってください。" >&2
    exit 1
fi
# 複数ホストのアプリホストで、migration を流さない役（ECCUBE_SKIP_DB_INIT=1）なら、スキーマに触らない。
# スキーマは init 役のホストで先に上げてある前提（docs/scale.md「EC-CUBE を上げる」）
app_role=0
if printf '%s\n' "$(compose_files_from_env)" | tr ':' '\n' | grep -qx compose.app.yaml; then
    multihost=1
    sk="$(env_get ECCUBE_SKIP_DB_INIT)"
    [ "${sk:-1}" = 1 ] && app_role=1
else
    multihost=0
fi

cat <<EOS
[upgrade] EC-CUBE をバージョンアップします。
          現在: ${current:-(未設定)}（PHP ${running_php:-${base_php:-?}}）
          変更後: ${ver}（PHP ${php_ver}）

  残るもの : DB(${db_vol}) / アップロード画像(${proj}_eccube_upload)
             app/Customize・app/template・app/Plugin など bind-mount 一式
  作り直し : 本体コード(${app_vol})。var/ 以下のログとキャッシュも消えます。

  注意:
   - 途中で失敗したら、自動で元の版に戻します（DB に手を付けていれば、取ったバックアップから戻します）。
   - 上げている間（バックアップ → 入れ替え → 確認）は、お客さんにはメンテナンス表示です。
   - 終わったあとで戻したくなったら: bin/upgrade.sh <元の版> のあと bin/restore.sh <バックアップ>
   - マイナー/メジャーをまたぐ場合、既存プラグインが新バージョン非対応だと起動後に
     エラーになることがあります。事前に対応状況を確認してください。
EOS
if [ "$multihost" = 1 ]; then
    if [ "$app_role" = 1 ]; then
        echo "  複数ホストのアプリホスト（migration を流さない役）です。DB のスキーマには触りません。"
        echo "  init 役のホストで先に上げてあることを確かめてください。"
    else
        echo "  **複数ホストの init 役です。ほかのアプリホストを先に止めてください**（止めていないと、上げている間も"
        echo "  そちらで注文が入り、失敗して DB を戻したときに消えます。docs/scale.md「EC-CUBE を上げる」）。"
    fi
fi
read -r -p "続行しますか? [y/N] " ans
[ "$ans" = "y" ] || { echo "中止しました"; exit 1; }

# 1) .env をそのまま写しておく。以降、元に戻すときはこれを書き戻す（値を 1 つずつ戻すと、足した行や
#    書き換えた行の戻し忘れが起きる）。
work="var/upgrade"
mkdir -p "$work"
cp -p .env "$work/env.before"
restore_env() {
    cp -p "$work/env.before" .env
    echo "[upgrade] .env を上げる前の状態に戻しました。" >&2
    # pull / build で同じタグが新しいものを指していたら、元に戻す（戻さないと、次の up や deploy が
    # 新しいイメージで古い本体を動かす）
    if [ -n "$old_image_id" ] && [ -n "$old_image_ref" ] && \
       [ "$(docker image inspect --format '{{.Id}}' "$old_image_ref" 2>/dev/null || true)" != "$old_image_id" ]; then
        docker tag "$old_image_id" "$old_image_ref" 2>/dev/null \
            && echo "[upgrade] イメージ ${old_image_ref} を上げる前のものに戻しました。" >&2
    fi
    return 0
}
if grep -qE '^ECCUBE_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^ECCUBE_VERSION=.*|ECCUBE_VERSION=${ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "ECCUBE_VERSION=${ver}" >> .env
fi

if [ "$redis_ver" != "$current_redis" ]; then
    echo "[upgrade] phpredis を ${redis_ver} に合わせます（EC-CUBE ${series} 系向け）。"
fi
# PHP_VERSION は手元で build するときに使う。配布イメージでもタグと揃えておく
# （あとで ECCUBE_IMAGE を外して build に切り替えたとき、古い PHP で焼かないため）。
if [ "$php_ver" != "$current_php" ]; then
    echo "[upgrade] PHP を ${php_ver} にします。"
fi
if grep -qE '^PHP_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^PHP_VERSION=.*|PHP_VERSION=${php_ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "PHP_VERSION=${php_ver}" >> .env
fi
if grep -qE '^PHPREDIS_VERSION=' .env 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^PHPREDIS_VERSION=.*|PHPREDIS_VERSION=${redis_ver}|" .env > "$tmp" && mv "$tmp" .env
else
    echo "PHPREDIS_VERSION=${redis_ver}" >> .env
fi

# 2b) 配布イメージを使っているなら、タグの系列も動かす。
#     マイナーをまたぐとき（4.3 -> 4.4）ここを忘れると、.env だけ新しくなって
#     **動くのは古い系列のイメージのまま**になる。build しないので
#     ECCUBE_VERSION は誰にも読まれず、食い違いに気づく機会が無い。
if [ -n "$current_image" ]; then
    # 系列と PHP の両方。-php を残したまま系列だけ変えると、新しい系列に無い PHP の
    # タグ（4.4-php8.1 など）を指して pull で止まる。
    retagged="$(image_retag_php "$(image_retag_series "$current_image" "$series")" "$php_ver")"
    if [ "$retagged" != "$current_image" ]; then
        tmp="$(mktemp)"
        sed "s|^ECCUBE_IMAGE=.*|ECCUBE_IMAGE=${retagged}|" .env > "$tmp" && mv "$tmp" .env
        echo "[upgrade] ECCUBE_IMAGE を ${retagged} に合わせました。"
        # **参照が変わったので取り直す。** 上で解決した $image は書き換え前の
        # タグを指しており、そのままだと下の事前確認が古いイメージを見る。
        image="$(docker compose config 2>/dev/null |
            awk '/^  ec-cube:$/{b=1;next} b&&/^  [a-zA-Z_-]+:$/{b=0} b&&/^    image:/{sub(/^    image: */,"");print;exit}')"
        if [ -z "$image" ]; then
            echo "[upgrade] エラー: ec-cube のイメージ名を取得できませんでした。" >&2
            restore_env
            exit 1
        fi
    fi
fi

# 3) 新バージョンのイメージを先に用意する。ここで落ちても稼働中の環境は無傷。
#    配布イメージなら pull、ローカル build 運用ならこれまでどおり build。
if ! image_provision "${dc[@]}"; then
    echo "[upgrade] エラー: イメージを用意できませんでした。稼働中の環境はそのままです。" >&2
    restore_env
    exit 1
fi

# 3a) 配布イメージは「焼かれたバージョン」が正。**.env の制約は build にしか
#     使われない**ので、実際に何が入ってきたのかをここで見せる。
#     `~4.3.2` と指定しても、タグが 4.3 系の古いビルドを指していれば 4.3.0 が来る。
if image_uses_registry; then
    baked="$(image_baked_version "$image")"
    if [ -n "$baked" ]; then
        echo "[upgrade] 取得したイメージの EC-CUBE: ${baked}（指定した制約: ${ver}）"
        echo "[upgrade] 制約どおりか確認してください。違えばタグを見直して中断できます。"
        read -r -p "このイメージで続行しますか? [y/N] " ans
        if [ "$ans" != "y" ]; then
            echo "[upgrade] 中止しました。稼働中の環境には触れていません。"
            restore_env
            exit 1
        fi
    else
        echo "[upgrade] 注意: イメージのバージョンを読めませんでした。" >&2
    fi
fi

# 3b) 新バージョンでプラグインと独自コードが読めるか、稼働中の環境に触る前に確かめる。
#     プラグインが新バージョン非対応だとクラス宣言の互換性チェックで Fatal error に
#     なり、あらゆる console コマンドが死ぬ。例（4.2 世代のプラグインを 4.3 に載せた場合）:
#
#       Fatal error: Declaration of Plugin\Foo\PluginManager::install(...
#       must be compatible with Eccube\Plugin\AbstractPluginManager::install(...
#
#     down してから気づくと切り戻しに時間がかかるので、ここで落として稼働中の環境を守る。
#     eccube_app ボリュームを渡さないので、新イメージの本体コードがそのまま使われる。
echo "[upgrade] 新バージョンでプラグインが読めるか確認します..."
preflight="$(docker run --rm \
    -v "$PWD/app/Plugin:/var/www/html/app/Plugin:ro" \
    -v "$PWD/app/Customize:/var/www/html/app/Customize:ro" \
    --entrypoint sh "$image" -c 'php bin/console list 2>&1' 2>&1 || true)"
if printf '%s' "$preflight" | grep -q 'Fatal error'; then
    echo "[upgrade] エラー: 新バージョンでコードを読み込めません。中止します。" >&2
    echo "[upgrade] 稼働中の環境・DB・画像には一切触れていません。" >&2
    echo >&2
    printf '%s\n' "$preflight" | grep -v '^Deprecated:' | grep 'Fatal error' | head -3 >&2
    echo >&2
    echo "[upgrade] 該当プラグインを新バージョン対応版へ更新するか、無効化・削除してから" >&2
    echo "          再実行してください（app/Plugin から外すだけでも確認できます）。" >&2
    restore_env
    exit 1
fi

# 止める前に、管理画面がコンテナ内 .env に書いた値を控える（読むだけ。動いたままでよい）。テーマ切替と
# セキュリティ設定はここに書かれ、ボリュームと一緒に消える。ホストの .env に
# 書いてあるものは環境変数で渡るので影響しない。それ以外だけ挙げる。
kept="$(docker run --rm -v "${app_vol}:/app:ro" alpine:3 sh -c '
    for k in ECCUBE_TEMPLATE_CODE ECCUBE_FRONT_ALLOW_HOSTS ECCUBE_FRONT_DENY_HOSTS \
             ECCUBE_ADMIN_ALLOW_HOSTS ECCUBE_ADMIN_DENY_HOSTS ECCUBE_FORCE_SSL TRUSTED_HOSTS; do
        grep -E "^${k}=" /app/.env 2>/dev/null
    done' 2>/dev/null || true)"
if [ -n "$kept" ]; then
    echo "[upgrade] 注意: 管理画面がコンテナ内 .env に書いていた値があります。ボリュームと一緒に消えます:"
    printf '%s\n' "$kept" | sed 's/^/           /'
    echo "           残すなら .env（ホスト）に同じキーを書いてください（環境変数で渡ります）。"
fi

# コンテナの中で composer require したライブラリは volume の中にしか無いので、ここで消える。
# 新しいイメージの composer.json（＝素の EC-CUBE）と突き合わせ、差分のうち
# app/Customize/composer.extra.json に宣言されていないものを挙げる（宣言済みのものは
# entrypoint が起動時に入れ直すので消えない）。
#
# **PHP は標準入力から渡す。** 以前は sh -c '…' の中の php -r "…" に書いていたが、
# PHP 側の文字列の二重引用符でシェルの引用が切れて毎回構文エラーになり、
# そのエラー文を「消えるライブラリ」として表示して確認を求めていた。
# 標準入力の無い実行（cron・nohup）では、その確認で止まる。
extra_rc=0
extra_lost="$(docker run --rm -i -v "${app_vol}:/app:ro" -v "${PWD}/app/Customize:/cust:ro" \
    --entrypoint php "$image" 2>/dev/null <<'PHP'
<?php
// 読めない・壊れているときは空として扱わない。「消えるものが無い」と誤って通してしまう。
// composer.extra.json だけは無くてよい（宣言していない店が普通）。
// 標準入力から読んだスクリプトでは STDERR 定数が無いので php://stderr へ書く。
$read = static function (string $path, bool $required): array {
    if (!is_file($path)) {
        if ($required) {
            file_put_contents("php://stderr", "読めません: {$path}\n");
            exit(2);
        }

        return [];
    }
    $json = json_decode((string) file_get_contents($path), true);
    if (!is_array($json)) {
        file_put_contents("php://stderr", "JSON として読めません: {$path}\n");
        exit(2);
    }

    return $json['require'] ?? [];
};
$vol = $read('/app/composer.json', true);
$img = $read('/var/www/html/composer.json', true);
$dec = $read('/cust/composer.extra.json', false);
$out = [];
foreach ($vol as $name => $version) {
    if (isset($img[$name]) || isset($dec[$name])) {
        continue;
    }
    if ($name === 'symfony/messenger' || $name === 'symfony/doctrine-messenger') {
        continue;
    }
    $out[] = $name.' '.$version;
}
echo implode("\n", $out);
PHP
)" || extra_rc=$?
if [ "$extra_rc" != 0 ]; then
    # 調べられなかったことを黙って通さない。消えるものが無い、とは言えない
    echo "[upgrade] 注意: コンテナの中で composer require したライブラリを調べられませんでした（終了コード ${extra_rc}）。"
    extra_lost="（確認できませんでした）"
fi
if [ -n "$extra_lost" ]; then
    echo "[upgrade] 注意: コンテナの中で composer require したライブラリがあります。ボリュームと一緒に消えます:"
    printf '%s\n' "$extra_lost" | sed 's/^/           /'
    echo "           残すには app/Customize/composer.extra.json に書いてください（git 管理。起動時に入れ直します）:"
    echo '             { "require": { "<名前>": "<バージョン>" } }'
    printf '           このまま続けますか? [y/N] '
    read -r ans_extra
    [ "$ans_extra" = "y" ] || { echo "[upgrade] 中止しました。稼働中の環境には触れていません。"; restore_env; exit 1; }
fi
# 4) メンテナンス表示にしてから、バックアップを取る。
#    **表示より先に取ると、取ってから止めるまでの間に入った注文がバックアップに無い。** 失敗して DB を
#    戻したときに、その注文が消える。表示の中で取り、公開前の確認もその中でする。
MAINT=/var/www/html/.maintenance
token="$(openssl rand -hex 16 2>/dev/null || date +%s)"
maint_on=0
# 手で入れていた表示の中身。新しい版のボリュームにも同じものを置き、終わっても外さない
manual_maint=""
# 始める前に表示があったか（中身が空のファイルもある。中身ではなくこちらで「外さない」を決める）
keep_maint=0
if [ -n "$("${dc[@]}" ps -q --status running ec-cube 2>/dev/null)" ]; then
    if "${dc[@]}" exec -T ec-cube sh -c "test -f $MAINT" 2>/dev/null; then
        # 手で入れたメンテナンス中。その token を借りて確認する（あとで外さない）
        keep_maint=1
        manual_maint="$("${dc[@]}" exec -T ec-cube sh -c "head -1 $MAINT" 2>/dev/null | tr -d '\r\n' || true)"
        [ -z "$manual_maint" ] || token="${manual_maint#*:}"
        echo "[upgrade] メンテナンス表示はすでに有効です（そのまま進めます。終わっても外しません）"
    elif "${dc[@]}" exec -T ec-cube runuser -u www-data -- sh -c "printf 'upgrade:%s' '$token' > $MAINT"; then
        maint_on=1
        echo "[upgrade] メンテナンス ON（お客さんには「メンテナンス中」。ログイン中の管理者は見えます）"
    else
        # 立てられないまま進むと、お客さんが注文できる状態でバックアップを取り、その後の注文が戻すときに消える
        echo "[upgrade] エラー: メンテナンス表示を立てられませんでした。中止します。稼働中の環境には触れていません。" >&2
        restore_env
        exit 1
    fi
elif docker volume inspect "$app_vol" >/dev/null 2>&1; then
    # **止まっているときも、手で入れていた表示を読む。** 読まないと新しい版のボリュームに upgrade: を置き、
    # 終わったときにそれを外すので、わざと閉じていた店を開けてしまう（#227 のレビュー）
    if docker run --rm -v "${app_vol}:/v:ro" alpine:3 test -f /v/.maintenance 2>/dev/null; then
        keep_maint=1
        manual_maint="$(docker run --rm -v "${app_vol}:/v:ro" alpine:3 head -1 /v/.maintenance 2>/dev/null | tr -d '\r\n' || true)"
        [ -z "$manual_maint" ] || token="${manual_maint#*:}"
        echo "[upgrade] メンテナンス表示はすでに有効です（そのまま進めます。終わっても外しません）"
    fi
fi
maint_off_running() {
    [ "$maint_on" = 1 ] || return 0
    "${dc[@]}" exec -T ec-cube sh -c "grep -q '^upgrade:' $MAINT && rm -f $MAINT" 2>/dev/null \
        && echo "[upgrade] メンテナンス OFF"
    return 0
}

# バックアップの途中で Ctrl-C・ssh の切断があっても、表示と .env を残さない（まだ何も壊していない）
worker_stopped=0
worker_back() { [ "$worker_stopped" = 1 ] && "${dc[@]}" start worker >/dev/null 2>&1; return 0; }
backup_interrupted() {
    trap - INT TERM HUP
    worker_back
    cp -p "$work/env.new" .env 2>/dev/null || true
    maint_off_running
    restore_env
    echo "[upgrade] バックアップの途中で止められました。稼働中の環境には触れていません。" >&2
    exit 1
}
trap backup_interrupted INT TERM HUP
# メールの worker を止める。戻すと送ったはずのメールが DB に戻り、もう一度送られる（注文確認の二重送信）
if printf '%s\n' "$services_now" | grep -qx worker && [ -n "$("${dc[@]}" ps -q --status running worker 2>/dev/null)" ]; then
    "${dc[@]}" stop worker >/dev/null 2>&1 && worker_stopped=1 && echo "[upgrade] メールの worker を止めました（終われば起動し直します）"
fi
# 表示を立てる前に受け付けた要求（注文の確定など）が終わるのを待ってから取る
if ! maint_drain "${dc[@]}"; then
    echo "[upgrade] 注意: 処理中の要求が 30 秒で終わりませんでした（ログイン中の管理者の操作かもしれません）。このまま取ります。"
fi
echo "[upgrade] バックアップを取得します（上げる前の .env で）..."
# バックアップの host.env は「上げる前」のものにする（戻すときの突き合わせと記録のため）
cp -p .env "$work/env.new"
cp -p "$work/env.before" .env
rf="$work/backup-result"; rm -f "$rf"
backup_ok=1
BACKUP_LABEL=upgrade BACKUP_RESULT_FILE="$rf" bin/backup.sh || backup_ok=0
cp -p "$work/env.new" .env
if [ "$backup_ok" != 1 ] || [ ! -s "$rf" ]; then
    echo "[upgrade] エラー: バックアップに失敗しました。中止します。稼働中の環境には触れていません。" >&2
    trap - INT TERM HUP
    worker_back
    maint_off_running
    restore_env
    exit 1
fi
backup_dir="$(cat "$rf")"
trap - INT TERM HUP
echo "[upgrade] バックアップ: ${backup_dir}"

# ── ここから先で失敗したら、自動で元の版に戻す ──
prev_vol="${app_vol}_before_upgrade"
vol_saved=0      # 本体ボリュームを写した
vol_removed=0    # 本体ボリュームを消した（消せていなければ、戻す必要は無い）
db_touched=0     # DB に書いた（スキーマ更新を始めた）
# site_code <path> … メンテナンス中でも token の cookie で中を見る（deploy.sh と同じ）
site_code() {
    local port
    port="$("${dc[@]}" port nginx 80 2>/dev/null | tail -1 | sed -E 's/^(0\.0\.0\.0|\[::\]):/localhost:/')"
    [ -n "$port" ] || port="localhost:$(env_get HTTP_PORT)"
    case "$port" in *:) port="${port}8080" ;; esac
    # X-Forwarded-Proto: https を付ける。付けないと ECCUBE_FORCE_SSL の店は https への転送（301/302）を返し、
    # 画面を組み立てずに「開いた」ことになる
    curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' -b "maintenance_token=${token}" "http://${port}${1}" || echo 000
}
wait_site() { # wait_site <秒>
    local deadline=$(( $(date +%s) + $1 )) code path
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # 200 だけを通す（転送は画面を組み立てていない）。トップと商品一覧の両方（DB とテンプレートを通る）
        code="$(site_code /)"
        if [ "$code" = 200 ]; then
            code="$(site_code /products/list)"
            [ "$code" = 200 ] && return 0
            path=/products/list
        else
            path=/
        fi
        sleep 5
    done
    echo "[upgrade] 応答: ${code:-000}（${path:-/}）" >&2
    return 1
}
# 公開前（メンテナンス表示の中）に開くかを見る時間。大きな店はキャッシュの組み立てに数分かかる
health_wait="${UPGRADE_HEALTH_TIMEOUT:-600}"

rollback_upgrade() {
    # パイプの中の子プロセスで呼ばれても、戻すのは親だけ
    [ "${BASH_SUBSHELL:-0}" = 0 ] || exit 1
    trap - ERR
    # 戻している間の Ctrl-C・切断は受けない（DB を戻している最中に止まると、表を消したところで終わる）
    trap '' INT TERM HUP
    local ok=1
    echo >&2
    echo "[upgrade] 失敗しました。元の版（${current:-?}）に戻します..." >&2
    "${dc[@]}" down >/dev/null 2>&1 || true
    cp -p "$work/env.before" .env
    echo "[upgrade]   .env を上げる前の状態に戻しました" >&2
    if [ -n "$old_image_id" ] && [ -n "$old_image_ref" ]; then
        if docker tag "$old_image_id" "$old_image_ref"; then
            echo "[upgrade]   イメージ ${old_image_ref} を上げる前のもの（${old_image_id#sha256:}）に戻しました" | sed -E 's/([0-9a-f]{12})[0-9a-f]{52}/\1/' >&2
        else
            ok=0; echo "[upgrade]   注意: 上げる前のイメージに戻せませんでした" >&2
        fi
    fi
    if [ "$vol_saved" = 1 ] && [ "$vol_removed" = 1 ]; then
        if docker volume rm -f "$app_vol" >/dev/null 2>&1 &&
           docker volume create --label "com.docker.compose.project=${proj}" --label com.docker.compose.volume=eccube_app "$app_vol" >/dev/null &&
           docker run --rm -v "${prev_vol}:/from:ro" -v "${app_vol}:/to" alpine:3 sh -c 'cp -a /from/. /to/'; then
            echo "[upgrade]   本体（${app_vol}）を上げる前のものに戻しました" >&2
        else
            ok=0; echo "[upgrade]   注意: 本体を戻せませんでした（上げる前のものは ${prev_vol} に残っています）" >&2
        fi
    fi
    if [ "$db_touched" = 1 ]; then
        echo "[upgrade]   DB を ${backup_dir} から戻します..." >&2
        "${dc[@]}" up --no-start >/dev/null 2>&1 || true
        # 一覧を変数に取ってから見る（pipefail の下で grep -q が先に終わると、前のコマンドが SIGPIPE で
        # 落ちて「無い」と判定し、DB を起こさずに戻そうとしていた。試験で踏んだ）
        services="$("${dc[@]}" config --services 2>/dev/null || true)"
        if printf '%s\n' "$services" | grep -qx db; then
            "${dc[@]}" up -d --wait db >/dev/null 2>&1 || true
        fi
        if bin/restore.sh --rollback --db-only "$backup_dir"; then
            echo "[upgrade]   DB を戻しました" >&2
        else
            ok=0; echo "[upgrade]   注意: DB を戻せませんでした" >&2
        fi
    else
        echo "[upgrade]   DB には書いていないので、そのままです" >&2
    fi
    # 元の版で起動し直す。**起動時の migration は流させない**（ECCUBE_SKIP_DB_INIT=1）。戻した DB は元の版の
    # 状態そのもので、流すものは無い。流すと、上げる途中で失敗した migration（app/DoctrineMigrations の
    # 独自のもの）をもう一度当てて、戻したばかりの DB を書き換える（entrypoint は失敗を握る）。
    local started=0
    if [ "$ok" = 1 ] && ECCUBE_SKIP_DB_INIT=1 "${dc[@]}" up -d && started=1 && wait_site "$health_wait"; then
        if [ "$maint_on" = 1 ]; then
            "${dc[@]}" exec -T ec-cube sh -c "grep -q '^upgrade:' $MAINT && rm -f $MAINT" 2>/dev/null || true
        fi
        cat >&2 <<EOS
[upgrade] **元の版（${current:-?}）に戻して、開くことを確かめました。**$([ "$maint_on" = 1 ] && printf ' メンテナンス表示も外しました。')
          上げられなかった原因は、上のエラーを見てください。
          上げる前のバックアップ: ${backup_dir}
EOS
    elif [ "$started" = 1 ]; then
        cat >&2 <<EOS
[upgrade] **.env・イメージ・本体・DB は上げる前に戻しましたが、元の版でも開きません。メンテナンス表示のままです。**
          上げる前から開かなかったか、上げる前後で変わらないもの（app/template・app/Customize・プラグイン・
          設定）に原因があります。ログ: docker compose logs ec-cube
          直したら: bin/plugin.sh reload のあと docker compose exec ec-cube rm /var/www/html/.maintenance
          上げる前のバックアップ: ${backup_dir}
EOS
    else
        # 次の bin/upgrade.sh が上げる前の本体の写しを上書きしないよう、印を置く
        date > "$work/rollback-failed" 2>/dev/null || true
        cat >&2 <<EOS
[upgrade] **元に戻すのも、最後まではできませんでした。メンテナンス表示のままです。**
          上げる前の状態は、ここに残っています（消さないでください）:
            .env       ${work}/env.before
            本体       ボリューム ${prev_vol}
            DB・画像   ${backup_dir}
          原因を直してから、この順で（compose の指定はこのサーバーのもの。本番なら本番構成）:
            cp ${work}/env.before .env
            ${dc[*]} down
            docker volume rm ${app_vol}
            docker volume create --label com.docker.compose.project=${proj} --label com.docker.compose.volume=eccube_app ${app_vol}
            docker run --rm -v ${prev_vol}:/from:ro -v ${app_vol}:/to alpine:3 sh -c 'cp -a /from/. /to/'
            ${dc[*]} up -d db            （外部 DB なら要らない）
            bin/restore.sh ${backup_dir}   （DB の退避が取れずに止まるなら RESTORE_WITHOUT_BACKUP=${proj} を前に付ける）
            ECCUBE_SKIP_DB_INIT=1 ${dc[*]} up -d
          開くことを確かめたら: rm ${work}/rollback-failed
EOS
    fi
    exit 1
}

# 5) 停止（-v は付けない = DB と画像は残る）→ 本体ボリュームを写してから作り直す
echo "[upgrade] コンテナを停止します（ボリュームは残します）..."
trap rollback_upgrade ERR INT TERM HUP
"${dc[@]}" down

# 本体ボリュームを写しておく（元の版の本体・vendor・コンテナ内 .env・var/）。戻すときはこれを書き戻す。
# 前回の upgrade の写しは、ここで置き換える（その時点のバックアップは backups/ にある）。
if docker volume inspect "$app_vol" >/dev/null 2>&1; then
    echo "[upgrade] 本体ボリュームを ${prev_vol} へ写します（失敗したときに戻すため）..."
    docker volume rm -f "$prev_vol" >/dev/null 2>&1 || true
    docker volume create --label "com.docker.compose.project=${proj}" --label eccube-docker.role=before-upgrade "$prev_vol" >/dev/null
    docker run --rm -v "${app_vol}:/from:ro" -v "${prev_vol}:/to" alpine:3 sh -c 'cp -a /from/. /to/'
    vol_saved=1
fi
echo "[upgrade] 本体ボリューム ${app_vol} を作り直します..."
docker volume rm "$app_vol" >/dev/null
vol_removed=1

# 6) 起動前にマーカーを置く。
#    ここで eccube_app が新イメージの内容で作られ、同時に .eccube_installed を置くことで
#    entrypoint の eccube:install 分岐（既存 DB を壊す）を回避して migration 経路に入る。
#    **メンテナンス表示も一緒に置く。** 新しいボリュームには表示が無いので、置かないと up した瞬間に
#    公開され、確認が終わる前に注文が入る（失敗して DB を戻すと、その注文が消える）。
echo "[upgrade] インストール済みマーカーを設定します..."
"${dc[@]}" run --rm --no-deps --entrypoint sh ec-cube \
    -c "mkdir -p /var/www/html/var && touch /var/www/html/var/.eccube_installed && printf '%s' '${manual_maint:-upgrade:${token}}' > ${MAINT} && chown www-data:www-data ${MAINT}"

# 7) 公開する前にスキーマとデータを合わせる。
#
#    ここで先に up -d してしまうと、新コード + 旧スキーマの状態で nginx が公開され、
#    スキーマ更新が終わるまで全ページ 500 を返す。そこで nginx を上げずに、db だけを
#    連れてくる使い捨てコンテナ（compose run）で先に整合させてから公開する。
#    ec-cube の depends_on は db / redis / redis-session なので、compose run では
#    nginx と worker は起動しない。
#
#    ECCUBE_SKIP_DB_INIT=1 / ECCUBE_SKIP_CACHE_CLEAR=1:
#    entrypoint には環境準備（app/config のマージ等）だけさせ、install や migrate は
#    撃たせない。適用順はこのスクリプトが制御する。
#
#    EC-CUBE 4.x のバージョンアップは 2 段構え:
#    DDL  : 本体の migration に ALTER/CREATE TABLE は 1 件も無く、スキーマの正は
#           エンティティ定義。よって doctrine:schema:update で DB を定義へ合わせる。
#           これを飛ばすと新しいエンティティが期待するカラムが無くて全ページ 500 に
#           なる（4.2 -> 4.3 なら dtb_base_info.ga_id）。
#           注意: schema:update は --complete の有無にかかわらず「エンティティ定義に
#           無い列」を削除する（--complete 無しで残るのはテーブルだけ）。よって
#           proxy を先に生成してプラグインの拡張をメタデータに載せ、そのうえで
#           差分に削除が混じっていないか確認してから --force する。
#    データ: 本体の migration（app/DoctrineMigrations の 18 件）はすべてデータ移行
#           （マスタ追加・不整合の是正など）。doctrine:migrations:migrate で流す。
#           カラムが揃ってから流したいので schema:update の後に実行する。
#           各 migration は存在チェックで保護されているので再実行は安全。
offline() { # offline <表示名> <console の引数...>
    local label="$1"; shift
    if ! "${dc[@]}" run --rm \
            -e ECCUBE_SKIP_DB_INIT=1 -e ECCUBE_SKIP_CACHE_CLEAR=1 \
            ec-cube runuser -u www-data -- php bin/console "$@"; then
        echo "[upgrade] エラー: ${label}に失敗しました。サイトはまだ公開していません。" >&2
        rollback_upgrade
    fi
}

# エンティティ proxy を先に作り直す。eccube_app を作り直すと app/proxy/entity が
# 消えるため、これを飛ばすと「有効なプラグインのエンティティ拡張」がメタデータに
# 載らない。schema:update は *エンティティ定義に無い列を削除する* ので、そのまま
# 流すとプラグインが追加した列（例: EntityExtension の dtb_customer.sort_no）を
# データごと落とす。
echo "[upgrade] エンティティ proxy を生成します..."
offline "proxy の生成" eccube:generate:proxies

if [ "$app_role" = 1 ]; then
    echo "[upgrade] アプリホスト（ECCUBE_SKIP_DB_INIT=1）なので、スキーマと migration には触りません（init 役で上げてある前提）。"
else
echo "[upgrade] 本体スキーマの差分:"
diff_sql="$("${dc[@]}" run --rm -e ECCUBE_SKIP_DB_INIT=1 -e ECCUBE_SKIP_CACHE_CLEAR=1 \
    ec-cube runuser -u www-data -- php bin/console doctrine:schema:update --dump-sql 2>&1 || true)"
printf '%s\n' "$diff_sql" | sed 's/^/    /'

# 列やテーブルの削除・名前の変更が混じっていないか確かめる。
# DROP INDEX / DROP FOREIGN KEY / DROP PRIMARY KEY は索引の貼り直しで普通に出るので
# 除外し、それ以外の DROP（＝列・テーブルの削除）だけを危険と見なす。
# **名前の変更も止める。** Doctrine DBAL 4（EC-CUBE 4.4）の比較器は、同じ表で「消える列」と「増える列」の
# 型が同じだと名前の変更とみなし、`CHANGE 古い 新しい`（MySQL）/ `RENAME COLUMN`（PostgreSQL）を打つ。
# データはそのまま別の列へ移る（CLAUDE.md「プラグインを入れ替えると、列のデータが別のプラグインへ移る」）。
# MySQL の CHANGE は型を変えるだけでも `CHANGE a a` と打つので、名前が違うものだけを拾う。
# 索引の名前の変更（RENAME INDEX / ALTER INDEX … RENAME TO）は普通に出るので外す。
risky="$(printf '%s' "$diff_sql" |
    sed -E 's/DROP (INDEX|FOREIGN KEY|PRIMARY KEY)[^,;]*//gi' |
    grep -iE 'DROP ' || true)"
renamed="$(printf '%s\n' "$diff_sql" | grep -oiE '(^|[ ,])CHANGE +(COLUMN +)?`?[A-Za-z0-9_]+`? +`?[A-Za-z0-9_]+`?' | sed -E 's/^[ ,]//' |
    tr -d '`' | awk '{ if (tolower($(NF-1)) != tolower($NF)) print }' || true)"
nl=$'\n'
renamed="${renamed:+${renamed}${nl}}$(printf '%s\n' "$diff_sql" | grep -iE 'RENAME +(COLUMN|TO) ' | grep -viE 'RENAME +INDEX|^[[:space:]]*ALTER +INDEX' || true)"
if { [ -n "$risky" ] && [ "${UPGRADE_ALLOW_DROP:-0}" != "1" ]; } || { [ -n "$renamed" ] && [ "${UPGRADE_ALLOW_RENAME:-0}" != "1" ]; }; then
    [ -z "$risky" ] || cat <<EOS >&2
[upgrade] エラー: スキーマ差分に列・テーブルの削除が含まれています。

$(printf '%s\n' "$risky" | sed 's/^/    /')

  これを適用すると上記のデータが失われます。よくある原因:
   - プラグインを無効化/アンインストールしたまま、その列が DB に残っている
   - プラグインが新バージョン非対応で、エンティティ拡張が読み込めていない
  該当プラグインを有効なまま新バージョン対応版へ更新するか、列が不要なら
  手動で削除してから再実行してください。
  内容を確認のうえ意図的に適用する場合のみ: UPGRADE_ALLOW_DROP=1 bin/upgrade.sh ${ver}
EOS
    [ -z "$renamed" ] || cat <<EOS >&2
[upgrade] エラー: スキーマ差分に列の名前の変更が含まれています。

$(printf '%s\n' "$renamed" | sed 's/^/    /')

  消える列と増える列を「名前の変更」とみなしたもので、適用すると古い列のデータが新しい列へ移ります
  （別のプラグインの列へ、ほかの意味の値が入る）。よくある原因は削除と同じです。
  内容を確認のうえ意図的に適用する場合のみ: UPGRADE_ALLOW_RENAME=1 bin/upgrade.sh ${ver}
EOS
    echo "[upgrade] DB にはまだ書き込んでいません。元の版に戻します。" >&2
    rollback_upgrade
fi

echo "[upgrade] スキーマを更新します（未公開）..."
db_touched=1
offline "スキーマ更新" doctrine:schema:update --force

echo "[upgrade] データ移行（migration）を適用します（未公開）..."
offline "migration の適用" doctrine:migrations:migrate --no-interaction --allow-no-migration
fi

# 8) ここまで整合してから起動する。entrypoint が cache:clear を行う。
#    **まだメンテナンス表示の中。** token の cookie で中から開くかを確かめ、通ったら外す。
echo "[upgrade] 起動します（メンテナンス表示のまま）..."
"${dc[@]}" up -d

echo "[upgrade] 開くかを確かめています（最大 ${health_wait} 秒。キャッシュの組み立てに数分かかることがあります）..."
if ! wait_site "$health_wait"; then
    echo "[upgrade] エラー: 新しい版が開きませんでした（ログ: docker compose logs ec-cube）。" >&2
    rollback_upgrade
fi
trap - ERR INT TERM HUP
# メンテナンス表示を外す。手で入れていたものは、新しい版にも同じものを置いたので残す。
# **止まっていたスタックを上げたときも外す。** そのときは始めに表示を立てない（maint_on=0）が、新しい版のボリュームには
# 必ず upgrade: の表示を置いて起動するので、maint_on で見ると外れずに 503 のまま残った（2 台の試験で踏んだ）
if [ "$keep_maint" = 0 ] && "${dc[@]}" exec -T ec-cube sh -c "grep -q '^upgrade:' $MAINT && rm -f $MAINT" 2>/dev/null; then
    echo "[upgrade] メンテナンス OFF"
elif [ "$keep_maint" = 1 ]; then
    echo "[upgrade] メンテナンス表示は、始める前から入っていたものなので残しています。"
fi
echo "[upgrade] 完了。${current:-?} -> ${ver} へ更新しました。"
bin/healthcheck.sh || true
# オリジナルテーマを写してあるなら、本体側で変わった静的物を挙げる。
# 写しはフォールバック無しで勝ち続けるので、**ここで見せないと誰も気づかない**。
# **.base があるだけでは出さない。** テーマを default のまま使っている店にも
# 写しが残っていることがあり（試しに init した、など）、無関係な差分で驚かせる。
if [ -f html/template/original/.base ] && [ "$(env_get ECCUBE_TEMPLATE_CODE)" = "original" ]; then
    echo "[upgrade] オリジナルテーマの写しと、新しい本体との差分:"
    bin/theme.sh diff || true
fi
echo "[upgrade] 管理画面とフロントの表示、受注データを必ず目視で確認してください。"
echo "          上げる前の状態: バックアップ ${backup_dir} / 本体 ${prev_vol}（次の upgrade で置き換わります）"
echo "          戻すなら: bin/upgrade.sh ${current:-<元の版>} のあと bin/restore.sh ${backup_dir}"
exit 0
