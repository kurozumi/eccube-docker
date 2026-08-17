#!/usr/bin/env bash
# 自作プラグインをサクッと導入・開発するためのヘルパー。
#
# プラグインは app/Plugin/<Code> に置く（dev では rw マウント）。private GitHub からの
# clone は「ホスト側の git/SSH 認証」をそのまま使うので、コンテナに秘密を渡さない。
#
# 使い方:
#   bin/plugin.sh add <git-url> [Code]  private repo を clone → install → enable
#   bin/plugin.sh install <Code>        既に app/Plugin/<Code> にある物を install → enable
#   bin/plugin.sh update <Code>         git pull → plugin:update/schema-update → cache:clear
#   bin/plugin.sh reload                キャッシュ一掃（PHP/config/twig を編集したら実行）
#   bin/plugin.sh enable  <Code>
#   bin/plugin.sh disable <Code>
#   bin/plugin.sh remove  <Code>        uninstall して app/Plugin/<Code> も削除
#   bin/plugin.sh list                  導入状況（ファイル + dtb_plugin）を表示
#   bin/plugin.sh doctor                システムエラーが出たときの点検と修復
#
# 開発を高速に回すコツ: .env を APP_ENV=dev にすると Twig/テンプレート変更は即反映。
# PHP/サービス/config を変えたら bin/plugin.sh reload。
# 各コマンドは prod と test の var/cache に加えて、キャッシュプール（Redis 上の
# Doctrine メタデータ）と OPcache も消す。cache:clear だけでは本番モードで
# 変更が反映されない。
set -euo pipefail
cd "$(dirname "$0")/.."

ec()  { docker compose exec -T ec-cube runuser -u www-data -- php bin/console "$@"; }
die() { echo "[plugin] エラー: $*" >&2; exit 1; }

# テスト環境のキャッシュも明示的に消す。
#
# なぜ: ここでの bin/console はコンテナの APP_ENV（既定は prod）で動く。本体の
# CacheUtil::clearCache() も指定が無ければ実行中の env だけが対象で、しかも
# Web の TerminateEvent で動く仕組みなので CLI では働かない。つまり
# prod 側は上の `ec cache:clear` で明示的に消しているのと同じ理由で、
# bin/test.sh が使う test 側も明示的に消しておく。
#
# 補足: プラグインの有効化・無効化については、消さなくても test 環境が
# 追随することを確認できた（コンテナが作り直されるため）。ただし本セッションで
# プラグイン追加直後に test 環境だけ古い定義が残る事象に遭遇しており、
# その再現条件は特定できていない。1 秒程度のコストなので保険として入れておく。
clear_test_cache() {
    docker compose exec -T -e APP_ENV=test -e APP_DEBUG=0 ec-cube \
        runuser -u www-data -- php bin/console cache:clear --no-warmup --no-interaction \
        >/dev/null 2>&1 || true
}

# キャッシュプール（Redis）を消す。
#
# Doctrine のメタデータは cache.system 経由で Redis に載る。プラグインが
# エンティティを拡張しても、ここが古いままだと
# 「Class Eccube\Entity\Product has no association named groups」で 500 になる。
clear_metadata_cache() {
    ec cache:pool:clear --all --no-interaction >/dev/null 2>&1 || true
}

# var/cache の外に残るキャッシュを消す。cache:clear だけでは足りない。
#
# 1) キャッシュプール（Redis）… 上の clear_metadata_cache を参照。
#
# 2) OPcache
#    本番モードは opcache.validate_timestamps=Off なので、ファイルを更新しても
#    php-fpm は古いコンパイル結果を返し続ける。プラグインコードを変えた直後に
#    「Trait Plugin\...\DeliveryTrait not found」が出るのはこれ。
#    php-fpm の master（PID 1）へ USR2 を送ると graceful reload され破棄される。
#
#    **CLI では OPcache が無効**なので bin/console からは正常に見える。
#    「コマンドは通るのにブラウザだけ壊れる」という切り分けにくい状態になるため、
#    キャッシュを消すときは必ずセットで行う。
clear_runtime_cache() {
    clear_metadata_cache
    docker compose exec -T ec-cube bash -c 'kill -USR2 1' >/dev/null 2>&1 || true
}

# プラグイン操作の「前」に Doctrine のメタデータキャッシュを落とす。
#
# eccube:plugin:install / enable / disable は app/proxy/entity を作り直してから
# 同じプロセスでスキーマ更新まで進む。このとき Redis に残った古いメタデータを
# 拾うと、メタデータ側には有る関連がクラス側には無い（あるいはその逆）状態になり
#   Property Eccube\Entity\Product::$BundleItems does not exist
# で異常終了する。var/cache を消すだけでは直らない（メタデータは Redis 側）。
#
# 実測（EC-CUBE 4.3.1-p1）: warm 済みの状態から
#   cache:clear --no-warmup のみ → install は上記エラーで失敗
#   cache:pool:clear --all      → install 成功
prepare_plugin_command() {
    clear_metadata_cache
}

# warmup 込みで cache:clear し、Doctrine のプロキシを作り直す。
#
# なぜ --no-warmup ではだめか:
#   doctrine.yaml の auto_generate_proxy_classes は '%kernel.debug%' なので
#   prod では false。つまり var/cache/<env>/doctrine/orm/Proxies/ の
#   __CG__EccubeEntity*.php は「キャッシュウォーマーが動いたときだけ」作られる。
#   ところが eccube:plugin:install / enable / disable の内部は
#   cache:clear --no-warmup までしか行わないため、EntityExtension トレイトを
#   適用し直した app/proxy/entity と Doctrine のプロキシがずれたまま残る。
#
# ずれると何が起きるか:
#   未初期化のプロキシに対して、トレイトで足した getter（例: Product の
#   getBundleItems()）を呼んでも override が無いので __load() が走らない。
#   getter 内の「null なら空の ArrayCollection を返す」実装がそのまま効いて、
#   **例外も出さずに空のコレクション**が返る。
#   $em->getRepository(...)->findBy(['Product' => $id]) は件数を返すのに
#   $Product->getBundleItems() は 0 件、という食い違いになり、
#   プラグインの Processor が黙って何も記録しない。
#
# 実測（EC-CUBE 4.3.1-p1）:
#   enable 直後                        … grep -c getBundleItems → 0
#   その後 warmup 込みの cache:clear   … grep -c getBundleItems → 3
#
# 組み立てまでこちらでやってしまう理由:
#   本体は管理画面も CLI も cache:clear --no-warmup までしか行わない
#   （CacheUtil::forceClearCache / PluginCommandTrait::clearCache）。空になった
#   あとの組み立ては次のリクエスト任せで、そこへ別のリクエストやコンソール
#   コマンドが重なると、コンパイル済みコンテナが書きかけのまま残る。実際に
#     Failed opening required '.../var/cache/prod/ContainerXXXX/getDoctrineOrmExtensionService.php'
#   で全ページがシステムエラーになった。先に温めておけば、ブラウザが来たときには
#   完成済みのものを読むだけになる。
warm_cache() {
    ec cache:clear --no-interaction >/dev/null 2>&1 || true
}

# 中断した操作の後始末。
#
# 1) .maintenance（auto_maintenance）
#    管理画面からプラグインを操作すると本体が自動で立てる。処理が途中で落ちると
#    消されずに残り、フロントだけ 503「ただいまメンテナンス中です」になる。
#    管理画面は素通りできるので、管理者は気づきにくい。
#    手動で入れたメンテナンス（mode が maintenance）は残す。
#
# 2) var/cache/.!!xxxx
#    cache:clear が旧ディレクトリをこの名前に改名してから消す。消し損ねると
#    たまり続ける。実際に14個・85MB 残っていた。
clean_leftovers() {
    docker compose exec -T ec-cube bash -c '
        if [ -f /var/www/html/.maintenance ] && grep -q "^auto_maintenance" /var/www/html/.maintenance; then
            rm -f /var/www/html/.maintenance
            echo "[plugin] 中断した操作のメンテナンス表示を解除しました"
        fi
        rm -rf /var/www/html/var/cache/.!!* 2>/dev/null || true
    ' 2>/dev/null || true
}

# 操作のあとに必ず通す一式。順番に意味がある。
#
#   後始末 → test/プール/OPcache を消す → warmup 込みで組み立て直す
#
# 組み立てを最後にするのは、先に温めても直後に OPcache を捨てると
# php-fpm がもう一度コンパイルし直すことになるため。
settle() {
    clean_leftovers
    clear_test_cache
    clear_runtime_cache
    warm_cache
}

# composer.json の extra.code を取り出す（php 非依存・grep/sed）
read_code() { # read_code <dir>
    grep -oE '"code"[[:space:]]*:[[:space:]]*"[^"]+"' "$1/composer.json" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/'
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  add)
    url="${1:-}"; want="${2:-}"
    [ -n "$url" ] || die "git URL を指定してください: bin/plugin.sh add <git-url> [Code]"
    tmp="app/Plugin/.tmp_add_$$"
    rm -rf "$tmp"
    echo "[plugin] clone: $url"
    git clone --depth 1 "$url" "$tmp" || die "clone に失敗（private なら SSH URL / gh auth を確認）"
    rm -rf "$tmp/.git"   # docker-eccube 側に .git を持ち込まない
    code="$(read_code "$tmp")"
    [ -n "$code" ] || die "composer.json の extra.code が読めません（EC-CUBE プラグインですか？）"
    if [ -n "$want" ] && [ "$want" != "$code" ]; then
        die "指定 Code '$want' と composer.json の code '$code' が不一致"
    fi
    dest="app/Plugin/$code"
    [ -e "$dest" ] && die "$dest は既に存在します（更新は bin/plugin.sh update ${code}）"
    mv "$tmp" "$dest"
    echo "[plugin] 配置: ${dest} （code=${code}）"
    prepare_plugin_command
    ec eccube:plugin:install --code="$code" --if-not-exists
    ec eccube:plugin:enable  --code="$code"
    settle
    echo "[plugin] 完了: $code を有効化しました"
    ;;

  install)
    code="${1:?Code を指定してください}"
    [ -d "app/Plugin/$code" ] || die "app/Plugin/$code がありません"
    prepare_plugin_command
    ec eccube:plugin:install --code="$code" --if-not-exists
    ec eccube:plugin:enable  --code="$code"
    settle
    echo "[plugin] 完了: $code"
    ;;

  update)
    code="${1:?Code を指定してください}"
    dir="app/Plugin/$code"
    [ -d "$dir" ] || die "$dir がありません"
    if [ -d "$dir/.git" ]; then
        echo "[plugin] git pull: $dir"; ( cd "$dir" && git pull --ff-only )
    else
        echo "[plugin] 注意: $dir は git 管理外（手動で最新化してください）"
    fi
    prepare_plugin_command
    ec eccube:plugin:update --code="$code" || true
    ec eccube:plugin:schema-update --code="$code" || true
    settle
    echo "[plugin] 更新完了: $code"
    ;;

  reload)
    settle
    echo "[plugin] キャッシュを消して温め直しました（var/cache・キャッシュプール・OPcache）"
    ;;

  enable)   prepare_plugin_command; ec eccube:plugin:enable  --code="${1:?Code}"; settle;;
  disable)  prepare_plugin_command; ec eccube:plugin:disable --code="${1:?Code}"; settle;;

  remove)
    code="${1:?Code を指定してください}"
    prepare_plugin_command
    ec eccube:plugin:disable   --code="$code" || true
    ec eccube:plugin:uninstall --code="$code" || true
    rm -rf "app/Plugin/$code"
    settle
    echo "[plugin] 削除完了: $code"
    ;;

  doctor)
    # 中断した操作の痕跡を探して直し、実際に画面が開くかまで見る。
    # 「システムエラーが出る」と言われたら、まずこれを実行する。
    ng=0
    clean_leftovers

    proxies="$(docker compose exec -T ec-cube bash -c \
        'ls /var/www/html/var/cache/prod/doctrine/orm/Proxies/ 2>/dev/null | wc -l' | tr -d ' \r')"
    echo "[doctor] Doctrine プロキシ: ${proxies} 件（0 でも prod は必要時に生成する設定）"

    if docker compose exec -T ec-cube test -f /var/www/html/.maintenance 2>/dev/null; then
        echo "[doctor] メンテナンス表示が有効です（手動で入れたものは解除しません）"
    fi

    echo "[doctor] キャッシュを組み立て直します"
    clear_runtime_cache
    warm_cache
    sleep 2

    base="${ECCUBE_BASE_URL:-http://localhost:8080}"
    for path in / /products/list /entry /admin/login; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "${base}${path}" || echo 000)"
        case "$code" in
            200|302) echo "[doctor] ${code} ${path}" ;;
            *)       echo "[doctor] ${code} ${path}  ← 異常"; ng=1 ;;
        esac
    done

    if [ "$ng" -eq 0 ]; then
        echo "[doctor] 問題なし"
    else
        echo "[doctor] 直りませんでした。var/log/prod/ の直近の CRITICAL を確認してください:"
        docker compose exec -T ec-cube bash -c \
            'grep -ohE "(CRITICAL|システムエラー).{0,200}" /var/www/html/var/log/prod/*.log 2>/dev/null | tail -3' || true
        exit 1
    fi
    ;;

  list)
    echo "=== app/Plugin/ にあるプラグイン ==="
    for d in app/Plugin/*/; do
        [ -d "$d" ] || continue
        c="$(read_code "$d")"; printf "  %-24s code=%s\n" "$(basename "$d")" "${c:-?}"
    done
    echo "=== 導入状況（dtb_plugin: enabled / version）==="
    docker compose exec -T db sh -c \
      'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -t -u root "$MYSQL_DATABASE" -e "SELECT code, enabled, version FROM dtb_plugin ORDER BY code;"' 2>/dev/null \
      || echo "（DB 未起動）"
    ;;

  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
