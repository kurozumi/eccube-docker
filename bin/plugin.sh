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
#   bin/plugin.sh watch [秒]            変更を見張って自動で reload（既定 2 秒間隔）
#   bin/plugin.sh enable  <Code>
#   bin/plugin.sh disable <Code>
#   bin/plugin.sh remove  <Code>        uninstall して app/Plugin/<Code> も削除
#   bin/plugin.sh list                  導入状況（ファイル + dtb_plugin）を表示
#   bin/plugin.sh doctor                システムエラーが出たときの点検と修復
#
#   プラグインのテンプレートを直す（プラグインは触らず、app/template/plugin/ に置く）:
#   bin/plugin.sh template add <Code> <相対パス>   原本を写して直せる状態にする（reload 込み）
#   bin/plugin.sh template diff                    自分が変えた / プラグイン側で変わった / 衝突
#   bin/plugin.sh template list                    写してあるもの
#   相対パスは app/Plugin/<Code>/Resource/template/ からのもの（例: admin/config.twig）。
#   **管理画面からは直さない**（履歴が残らない）。ファイルに置いて git で持つ。
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
#
# **失敗を握りつぶさない。** ここが黙って落ちると、[plugin] は成功と表示するのに
# 古いコンパイル済みコンテナが残る。本番モードでは「足したサービスやタグだけが
# 例外も 500 も出さずに効かない」という形になり、原因にたどり着けない。
# **実際に踏んだ**（warmup が 256M のメモリ上限に当たって落ちていた）。
#
# メモリ上限は既定の 1G を使う。プラグインを何十個も入れると warmup は重く、
# php.ini の memory_limit（既定 256M）では足りない。変えたいときは
# PLUGIN_CACHE_MEMORY_LIMIT で上書きする。
#
# **進捗を出す。** 出力をコマンド置換で抱え込むと、終わるまで画面が沈黙する。
# プラグインを何十個も入れた環境では数分かかるので、**固まったと勘違いして
# 止めたくなる。** 途中で止めるとコンパイル済みコンテナが消えたまま残り、
# 全ページが 500 になる。**実際にそれでサイトを落とした。**
#
# **出力はパイプに通さない。** `| tail` のように読み手を挟むと、その読み手を
# 先に止めたときコンテナの中の php が書き込みでブロックし、いつまでも
# 終わらなくなる。ファイルへ落として、失敗したときだけ読む。
warm_cache() {
    local limit="${PLUGIN_CACHE_MEMORY_LIMIT:-1G}"
    local log
    log=$(mktemp)

    echo "[plugin] キャッシュを組み立てています（数分かかることがあります。止めないでください）"

    if docker compose exec -T ec-cube runuser -u www-data -- \
            php -d memory_limit="$limit" bin/console cache:clear --no-interaction >"$log" 2>&1; then
        rm -f "$log"

        return 0
    fi

    local out
    out=$(cat "$log")
    rm -f "$log"

    echo "[plugin] キャッシュの組み立てに失敗しました（memory_limit=${limit}）。" >&2
    echo "[plugin] **古いコンパイル済みコンテナが残っています。**" >&2
    echo "[plugin] 本番モードでは、足したサービスやタグが例外も 500 も出さずに" >&2
    echo "[plugin] 効かないという形で出ます。直してからもう一度実行してください。" >&2
    echo "$out" | tail -n 15 | sed 's/^/[plugin]   /' >&2

    return 1
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
# clean_leftovers [--with-deploy]
#   auto_maintenance … 本体がプラグイン操作で自動で立てたもの → いつでも解除する
#   deploy:          … bin/deploy.sh が立てたもの → **doctor のときだけ**解除する
#   maintenance      … 手で入れたもの → 触らない
# deploy: を reload でも消すと、**bin/deploy.sh が途中で呼ぶ reload がメンテナンス表示を
# 剥がしてしまい、キャッシュ組み立て中の壊れた画面が公開される**（実際にそうなった）。
clean_leftovers() {
    local pat="^auto_maintenance"
    [ "${1:-}" = "--with-deploy" ] && pat="^(auto_maintenance|deploy:)"
    docker compose exec -T ec-cube bash -c '
        if [ -f /var/www/html/.maintenance ] && grep -qE "'"$pat"'" /var/www/html/.maintenance; then
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
# **warm_cache の失敗をそのまま返す。** 呼び出し側（set -e）が止まるので、
# 「成功と表示されたのに古いキャッシュが残る」ことがなくなる。
settle() {
    clean_leftovers
    clear_test_cache
    clear_runtime_cache
    warm_cache
}

# コンパイル済みコンテナより新しいファイルを1つ返す（無ければ空文字）。
#
# 本番モードではコンパイル済みコンテナも OPcache も**こちらが消すまで作り直されない**。
# ファイルを更新しただけの状態は、例外も 500 も出さずに「その変更だけが無かったこと
# になる」という形で出る。実際に踏んだ例:
#   承認対象を決めるクラス（タグ付きサービス）を1つ足したのに、コンテナには
#   古い並びが焼かれたままで、取引先の会員登録が承認制にならなかった。
#   コードもタグも正しいので、grep でもテストでも見つからない。
#
# 基準にするのはコンパイル済みコンテナの更新時刻。reload / settle が作り直すので、
# 「最後にキャッシュを組み立てた時刻」として使える。
#
# dev では debug モードがファイルの更新を追うので、この比較は行わない
# （コンテナのファイル名も別で、そもそも存在しない）。
# Tests 配下はコンテナに入らないので無視する（bin/test.sh の 4.6 と同じ理由）。
stale_file() {
    docker compose exec -T ec-cube sh -c '
        c=/var/www/html/var/cache/prod/Eccube_KernelProdContainer.php
        [ -f "$c" ] || exit 0
        find /var/www/html/app/Plugin /var/www/html/app/Customize \
            -type f \( -name "*.php" -o -name "*.yaml" -o -name "*.yml" -o -name "*.xml" -o -name "*.twig" \) \
            -not -path "*/Tests/*" -not -path "*/vendor/*" -not -path "*/node_modules/*" \
            -newer "$c" -print -quit 2>/dev/null
    ' 2>/dev/null || true
}

# composer.json の extra.code を取り出す（php 非依存・grep/sed）
#
# 読めなければ空文字を返す。末尾の `|| true` が要る理由:
# grep は一致が無いと 1 を返し、`set -euo pipefail` の pipefail でパイプライン全体が
# 非ゼロになる。`c="$(read_code "$d")"` は代入の終了ステータスがそのまま置換の
# ステータスなので、set -e で**その場でスクリプトが終了する**。しかも表示済みの
# 行までしか出ないので、失敗したことに気づけない。
read_code() { # read_code <dir>
    grep -oE '"code"[[:space:]]*:[[:space:]]*"[^"]+"' "$1/composer.json" 2>/dev/null \
        | head -1 | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/' || true
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  add)
    url="${1:-}"; want="${2:-}"
    [ -n "$url" ] || die "git URL を指定してください: bin/plugin.sh add <git-url> [Code]"
    tmp="app/Plugin/.tmp_add_$$"
    rm -rf "$tmp"
    # 途中で落ちても作業ディレクトリを app/Plugin/ に残さない。
    # die は exit するので EXIT で拾う（成功時は mv 済みで、この rm は空振りする）。
    trap 'rm -rf "$tmp"' EXIT
    echo "[plugin] clone: $url"
    git clone --depth 1 "$url" "$tmp" || die "clone に失敗（private なら SSH URL / gh auth を確認）"
    rm -rf "$tmp/.git"   # eccube-docker 側に .git を持ち込まない
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
    # **`<code>` は位置引数。** 4.4 の update / schema-update に --code は無く、
    # 付けると「The "--code" option does not exist」で落ちる。
    # **失敗を握りつぶさない。** 以前は `|| true` で流していたので、CRITICAL が
    # 2 行出たあとに「更新完了」と表示され、dtb_plugin の version も
    # PluginManager::update() も動かないままだった（実際にそうなった）。
    # ファイルは pull で新しくなっているので、失敗してもキャッシュは組み立て直す
    # （組み立てないと、消えたクラスを参照したコンテナが残って落ちる）。
    if ! ec eccube:plugin:update "$code"; then
        settle
        die "eccube:plugin:update が失敗しました。ファイルは新しくなっています（キャッシュは組み立て直しました）。
       上のエラーを直してから、もう一度 bin/plugin.sh update $code"
    fi
    ec eccube:plugin:schema-update "$code" || echo "[plugin] 注意: schema-update が失敗しました（スキーマを持たないプラグインなら無視してよい）"
    settle
    echo "[plugin] 更新完了: $code"
    ;;

  reload)
    settle
    echo "[plugin] キャッシュを消して温め直しました（var/cache・キャッシュプール・OPcache）"
    ;;

  # 変更を見張って自動で reload する。
  #
  # 本番モードの取りこぼしは「reload を忘れた」ではなく「忘れても気づけない」ことが
  # 問題なので、忘れる前提で動かしておく。git pull でプラグインを更新したときにも効く。
  # bin/assets.sh watch と同じ感覚で、開発中は別のターミナルで放っておく。
  #
  # fswatch 等は使わない。見張るのはコンテナの中のファイルで、ホストに何も
  # 入れさせないため。settle 自体に数秒かかるので、これがそのまま連打よけになる。
  watch)
    interval="${1:-2}"
    if [ -z "$(docker compose exec -T ec-cube sh -c \
        '[ -f /var/www/html/var/cache/prod/Eccube_KernelProdContainer.php ] && echo y' 2>/dev/null || true)" ]; then
        echo "[plugin] 本番モードのコンパイル済みコンテナがありません。"
        echo "[plugin] APP_ENV=dev なら debug モードが更新を追うので watch は要りません。"
        exit 0
    fi
    echo "[plugin] app/Plugin と app/Customize を見張ります（${interval}秒ごと・Ctrl-C で終了）"
    while :; do
        changed="$(stale_file)"
        if [ -n "$changed" ]; then
            echo "[plugin] 変更を検出: ${changed#/var/www/html/}"
            settle
            echo "[plugin] 反映しました（$(date '+%H:%M:%S')）"
        fi
        sleep "$interval"
    done
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
    ng=0     # 直っていない異常
    warn=0   # 異常とは限らないが、伝えておくこと
    clean_leftovers --with-deploy

    # 数え損ねても doctor 自体は続ける（set -e + pipefail で黙って止まらないように）
    proxies="$(docker compose exec -T ec-cube bash -c \
        'ls /var/www/html/var/cache/prod/doctrine/orm/Proxies/ 2>/dev/null | wc -l' 2>/dev/null \
        | tr -d ' \r' || true)"
    echo "[doctor] Doctrine プロキシ: ${proxies:-?} 件（0 でも prod は必要時に生成する設定）"
    if [ -z "$proxies" ]; then
        echo "[doctor] 注意: ec-cube コンテナに届きませんでした（docker compose ps を確認）"
        warn=1
    fi

    if docker compose exec -T ec-cube test -f /var/www/html/.maintenance 2>/dev/null; then
        echo "[doctor] メンテナンス表示が有効です（手動で入れたものは解除しません）"
    fi

    # コンパイル済みコンテナが、いま置いてあるファイルより古くないか。
    #
    # **これは「エラーが出ない不具合」なので、doctor で挙げる価値がいちばん高い。**
    # 足したサービスやタグが効かないだけなので、画面は 200 で開き、ログにも何も出ない。
    # 下の疎通確認も通ってしまう。
    stale="$(stale_file)"
    if [ -n "$stale" ]; then
        echo "[doctor] コンパイル済みコンテナより新しいファイルがあります:"
        echo "           ${stale#/var/www/html/}"
        echo "           本番モードは更新を見ないので、この変更はまだ効いていません"
        echo "           （下でキャッシュを組み立て直すので、このあと反映されます）"
        warn=1
    else
        echo "[doctor] コンパイル済みコンテナ: 最新"
    fi

    # インストール済みなのに無効なプラグインを挙げる。
    #
    # 中断した操作で勝手に無効へ落ちることがある。無効になっただけでは
    # 「エラー」に見えないが、他のプラグインがそのエンティティ拡張を前提に
    # していると、Doctrine のメタデータと実体がずれて画面が落ちる。
    disabled="$(docker compose exec -T db sh -c \
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -N -B -u root "$MYSQL_DATABASE" \
         -e "SELECT code FROM dtb_plugin WHERE initialized = 1 AND enabled = 0 ORDER BY code;"' \
        2>/dev/null | tr -d '\r' || true)"
    if [ -n "$disabled" ]; then
        echo "[doctor] インストール済みだが無効なプラグイン:"
        echo "$disabled" | sed 's/^/           /'
        echo "           意図的でなければ bin/plugin.sh enable <Code> で戻してください"
        warn=1
    fi

    # エンティティ拡張が、生成されたクラスに入っているかを見る。
    #
    # 有効なプラグインの #[EntityExtension] が app/proxy/entity 側に反映されて
    # いないと「Property Plugin\...\Group::$optionEntry does not exist」で落ちる。
    # 拡張を持つプラグインが無効に落ちた直後に必ず起きる形。
    trait_ng="$(docker compose exec -T ec-cube php <<'PHP' 2>/dev/null || true
<?php
$root = '/var/www/html';

// 有効なプラグインだけを見る。app/Plugin/ には未導入のものも置いてある。
$enabled = [];
$dsn = getenv('DATABASE_URL');
if ($dsn && ($u = parse_url($dsn))) {
    try {
        // DB の種類は DATABASE_URL のスキームから（mysql / postgresql）
        $pg = in_array($u['scheme'] ?? '', ['postgresql', 'postgres', 'pgsql'], true);
        $pdo = new PDO(
            sprintf('%s:host=%s;port=%d;dbname=%s', $pg ? 'pgsql' : 'mysql', $u['host'], $u['port'] ?? ($pg ? 5432 : 3306), ltrim($u['path'] ?? '', '/')),
            urldecode($u['user'] ?? ''),
            urldecode($u['pass'] ?? '')
        );
        // PostgreSQL では enabled が boolean なので `= 1` は型エラーになる。TRUE は両方で通る
        $enabled = $pdo->query('SELECT code FROM dtb_plugin WHERE enabled = TRUE')
            ->fetchAll(PDO::FETCH_COLUMN);
    } catch (Throwable $e) {
        // DB を読めないときは判定しない（誤検知よりは黙るほうがまし）
        exit(0);
    }
}
if (!$enabled) {
    exit(0);
}

foreach ($enabled as $code) {
    foreach (glob($root.'/app/Plugin/'.$code.'/Entity/*.php') ?: [] as $file) {
        $src = file_get_contents($file);
        if (!str_contains($src, 'EntityExtension')) {
            continue;
        }
        if (!preg_match('/EntityExtension\(\s*\\\\?([A-Za-z0-9_\\\\]+)::class/', $src, $m)
            || !preg_match('/^namespace\s+([^;]+);/m', $src, $ns)
            || !preg_match('/^\s*trait\s+(\w+)/m', $src, $t)) {
            continue;
        }

        $target = ltrim($m[1], '\\');
        if (!str_contains($target, '\\')) {
            // 短い名前で書いてあるものは use 文から補う
            if (preg_match('/^use\s+([A-Za-z0-9_\\\\]*\\\\'.preg_quote($target, '/').');/m', $src, $imp)) {
                $target = $imp[1];
            } else {
                continue;
            }
        }
        $trait = trim($ns[1]).'\\'.$t[1];

        // 生成先: Eccube\Entity\X -> src/Eccube/Entity/X.php / Plugin\Y\Entity\X -> app/Plugin/Y/Entity/X.php
        $rel = str_starts_with($target, 'Eccube\\')
            ? 'src/'.str_replace('\\', '/', $target).'.php'
            : 'app/'.str_replace('\\', '/', $target).'.php';
        $proxy = $root.'/app/proxy/entity/'.$rel;

        if (!is_file($proxy)) {
            echo "生成なし: {$target}（{$trait}）\n";
            continue;
        }
        if (!str_contains(file_get_contents($proxy), $trait)) {
            echo "未反映: {$target} に {$trait} が入っていません\n";
        }
    }
}
PHP
)"
    if [ -n "$trait_ng" ]; then
        echo "[doctor] エンティティ拡張の反映漏れ:"
        echo "$trait_ng" | sed 's/^/           /'
        echo "           bin/plugin.sh reload で直らなければ、該当プラグインを enable し直してください"
        ng=1
    else
        echo "[doctor] エンティティ拡張: 反映済み"
    fi

    # 管理画面が本番で書いたファイルのうち、git にまだ入っていないもの。
    #
    # CSS 管理 / JS 管理 / ページ管理 / ブロック管理はディスクに書く。bind mount
    # なのでホストにはあるが、コミットされない限り**このサーバーにしか無い**。
    # bin/backup.sh には入るが、引っ越しを git だけでやると消える。
    # 壊れているわけではないので warn 止まり。
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        dirty="$(git status --porcelain -- app/template html/user_data/assets/css html/user_data/assets/js 2>/dev/null || true)"
        if [ -n "$dirty" ]; then
            echo "[doctor] 管理画面が書いたと思われる、コミットされていないファイル:"
            printf '%s\n' "$dirty" | sed 's/^/           /'
            echo "           git にも残すならコミット。残さないなら bin/backup.sh には入っています"
            warn=1
        else
            echo "[doctor] 管理画面が書いたファイル: すべてコミット済み"
        fi
    fi

    # customize.css の先頭が @import か。
    #
    # customize.css は管理画面（CSS 管理）が丸ごと書き換えるファイルで、テーマ
    # （customize-theme.css）は先頭の @import で読み込んでいる。CSS の仕様上、
    # @import は他のルールより前に無いと**黙って無視される**。店が上に書き足すと
    # テーマが丸ごと効かなくなるが、エラーは出ず、ページも 200 で開く。
    css=html/user_data/assets/css/customize.css
    if [ -f "$css" ]; then
        # コメントと空行を除いた最初の 1 行を見る。**sed は使わない。** 1 行ずつしか
        # 見ないので、複数行の /*! ... */ を剥がせず、必ず「先頭が @import でない」と
        # 誤判定する（実際にそうなった）。perl なら複数行をまたいで消せる。
        if command -v perl >/dev/null 2>&1; then
            first="$(perl -0pe 's{/\*.*?\*/}{}gs' "$css" | grep -vE '^[[:space:]]*$' | head -1 || true)"
        else
            first="@import"   # perl が無ければ判定しない（誤検知で ng にしない）
            echo "[doctor] customize.css: perl が無いので @import の位置は確認していません"
        fi
        case "$first" in
            @charset*|@import*) echo "[doctor] customize.css: @import が先頭にあります" ;;
            *)
                echo "[doctor] customize.css の先頭が @import ではありません:"
                echo "           ${first:-（空）}"
                echo "           テーマ（customize-theme.css）が読み込まれていません。"
                echo "           管理画面（CSS 管理）で、@import url(\"customize-theme.css\"); を 1 行目に戻してください"
                ng=1
                ;;
        esac
    fi

    # テーマコードに対応する静的物があるか。asset() の base_path は
    # /html/template/<コード> の 1 本でフォールバックが無いので、無いと
    # **サイトの CSS と画像が丸ごと 404** になる。ページ自体は 200 で開く。
    tcode="$(docker compose exec -T ec-cube sh -c 'printf %s "${ECCUBE_TEMPLATE_CODE:-default}"' 2>/dev/null | tr -d '\r' || true)"
    if [ -n "$tcode" ] && [ "$tcode" != "default" ]; then
        if docker compose exec -T ec-cube test -f "/var/www/html/html/template/${tcode}/assets/css/style.css" 2>/dev/null; then
            echo "[doctor] テーマ ${tcode}: 静的物あり"
        else
            echo "[doctor] テーマ ${tcode} の静的物がありません（html/template/${tcode}/assets/css/style.css）"
            echo "           サイトの CSS と画像が 404 になっています。bin/theme.sh init で本体から写してください"
            ng=1
        fi
    fi

    # 任意機能（redis / messenger）の整合。スイッチは COMPOSE_PROFILES 一本だが、
    # 「.env を変えたのに up -d していない」と、コンテナが見ている値と実際に
    # 起動しているサービスがずれる。ずれ方によって症状が違う:
    #   設定あり・Redis なし  → 全ページ 500（接続失敗）
    #   設定あり・worker なし → メールが DB に溜まり続けて誰にも届かない（**エラーなし**）
    cprof=",$(docker compose exec -T ec-cube sh -c 'printf %s "${ECCUBE_PROFILES:-}"' 2>/dev/null | tr -d '\r'),"
    hprof=",$(grep -E '^COMPOSE_PROFILES=' .env 2>/dev/null | head -1 | cut -d= -f2-),"
    if [ "$cprof" != "$hprof" ]; then
        echo "[doctor] .env の COMPOSE_PROFILES（${hprof#,}）とコンテナが見ている値（${cprof#,}）が違います"
        echo "           docker compose up -d で作り直してください（設定の投入は起動時に決まります）"
        warn=1
    fi
    running="$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null | tr '\n' ' ')"
    case "$cprof" in *,redis,*)
        case " $running " in *" redis "*) echo "[doctor] redis: 有効・起動中" ;;
            *) echo "[doctor] redis の設定が入っているのに redis コンテナが動いていません（全ページ 500 の原因）"; ng=1 ;;
        esac ;;
    esac
    case "$cprof" in *,messenger,*)
        case " $running " in *" worker "*) echo "[doctor] messenger: 有効・worker 起動中" ;;
            *) echo "[doctor] messenger の設定が入っているのに worker が動いていません。**メールが DB に溜まって届きません**"; ng=1 ;;
        esac
        # 溜まっている数。多ければ worker が消化できていない
        q="$(docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -N -B -u root "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM messenger_messages WHERE delivered_at IS NULL;"' 2>/dev/null | tr -d '\r' || true)"
        [ -n "$q" ] && [ "$q" -gt 0 ] 2>/dev/null && { echo "[doctor] 未送信のメールが ${q} 件キューにあります"; warn=1; }
        ;;
    esac

    echo "[doctor] キャッシュを組み立て直します"
    clear_runtime_cache
    # **ここでは止まらない。** 点検の途中なので、失敗も所見として拾って先へ進む
    if ! warm_cache; then
        echo "[doctor] キャッシュの組み立てに失敗しました。上の理由を直してください" >&2
        ng=1
    fi
    sleep 2

    base="${ECCUBE_BASE_URL:-http://localhost:8080}"
    page_ng=0
    for path in / /products/list /entry /admin/login; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "${base}${path}" || echo 000)"
        case "$code" in
            200|302) echo "[doctor] ${code} ${path}" ;;
            *)       echo "[doctor] ${code} ${path}  ← 異常"; page_ng=1; ng=1 ;;
        esac
    done

    # ログを出すのはページが落ちたときだけにする。過去のエラーが残っていても
    # いま壊れているとは限らず、混乱するだけなので。
    if [ "$page_ng" -eq 1 ]; then
        echo "[doctor] var/log/prod/ の直近の CRITICAL:"
        docker compose exec -T ec-cube bash -c \
            'grep -ohE "(CRITICAL|システムエラー).{0,200}" /var/www/html/var/log/prod/*.log 2>/dev/null | tail -3' \
            | sed 's/^/           /' || true
    fi

    if [ "$ng" -ne 0 ]; then
        echo "[doctor] 上に挙げた点を直してください"
        exit 1
    elif [ "$warn" -ne 0 ]; then
        echo "[doctor] 画面は開いています。上の注意点だけ確認してください"
    else
        echo "[doctor] 問題なし"
    fi
    ;;

  # ── プラグインのテンプレートを app/template/plugin/ で上書きする ──
  #
  # 本体は有効なプラグインごとに app/template/plugin/<Code>/ を先、
  # app/Plugin/<Code>/Resource/template/ を後で twig のパス（@<Code>）に登録する
  # （EccubeExtension::configureTwigPaths）。直すファイルだけ写して置けば、
  # プラグインを触らずに画面を変えられる。
  #
  # **写しはプラグインを更新しても勝ち続ける。** 写した時点の原本の sha256 を
  # app/template/plugin/.base に記録し、diff で「自分が変えた」「プラグイン側で
  # 変わった」「両方（衝突）」を分けて出す（bin/theme.sh と同じ構造）。
  #
  # ディレクトリの有無はコンテナのコンパイル時に見られるので、add の最後に reload する。
  template)
    tbase=app/template/plugin/.base
    if command -v sha256sum >/dev/null 2>&1; then tsha="sha256sum"; else tsha="shasum -a 256"; fi
    # shellcheck disable=SC2086
    fsha() { $tsha "$1" | cut -d' ' -f1; }
    # 先頭で shift 済みなので、サブコマンドは $1、以降は $2 $3
    case "${1:-}" in
      add)
        code="${2:-}"; rel="${3:-}"
        [ -n "$code" ] && [ -n "$rel" ] || die "使い方: bin/plugin.sh template add <Code> <相対パス>   例: template add CustomerGroup44 admin/config.twig"
        src="app/Plugin/${code}/Resource/template/${rel}"
        dst="app/template/plugin/${code}/${rel}"
        [ -f "$src" ] || die "原本がありません: ${src}
       相対パスは app/Plugin/${code}/Resource/template/ からのものです。候補:
$(cd "app/Plugin/${code}/Resource/template" 2>/dev/null && find . -name '*.twig' | sed 's#^\./#         #' | head -20)"
        [ -f "$dst" ] && die "すでに写してあります: ${dst}（直すならそのファイルを編集。差分は template diff）"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        printf '%s  %s/%s\n' "$(fsha "$src")" "$code" "$rel" >> "$tbase"
        echo "[plugin] 写しました: ${dst}"
        echo "[plugin] ここを直してください。原本（${src}）は触らないこと。"
        echo "[plugin] 登録はコンパイル時に決まるので、キャッシュを組み立て直します..."
        settle
        echo "[plugin] 完了。git add ${dst} ${tbase} して控えを残してください。"
        ;;
      diff)
        [ -f "$tbase" ] || { echo "[plugin] 写しはありません（bin/plugin.sh template add）"; exit 0; }
        mine=""; theirs=""; both=""; gone=""
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            bsha="${line%%  *}"; path="${line#*  }"
            code="${path%%/*}"; rel="${path#*/}"
            ours="app/template/plugin/${path}"; orig="app/Plugin/${code}/Resource/template/${rel}"
            if [ ! -f "$orig" ]; then gone="${gone}    ${path}\n"; continue; fi
            m=0; t=0
            [ -f "$ours" ] && [ "$(fsha "$ours")" != "$bsha" ] && m=1
            [ "$(fsha "$orig")" != "$bsha" ] && t=1
            [ "$m" = 1 ] && mine="${mine}    ${path}\n"
            [ "$t" = 1 ] && theirs="${theirs}    ${path}\n"
            [ "$m" = 1 ] && [ "$t" = 1 ] && both="${both}    ${path}\n"
        done < "$tbase"
        if [ -z "$mine$theirs$gone" ]; then echo "[plugin] 差分なし。写したときのままで、プラグイン側も変わっていません。"; exit 0; fi
        [ -n "$mine" ]   && { echo "[plugin] あなたが変えたファイル:"; printf '%b' "$mine"; }
        [ -n "$theirs" ] && { echo "[plugin] プラグイン側で変わったファイル。**いまはあなたの写しが勝っている**:"; printf '%b' "$theirs"
                              echo "         比べる: diff app/Plugin/<Code>/Resource/template/<相対パス> app/template/plugin/<Code>/<相対パス>"; }
        [ -n "$both" ]   && { echo "[plugin] **両方が変えたファイル（衝突）**。手で合わせてください:"; printf '%b' "$both"; }
        [ -n "$gone" ]   && { echo "[plugin] プラグイン側から原本が消えたファイル（写しは無効かもしれない）:"; printf '%b' "$gone"; }
        [ -n "$theirs" ] && echo "[plugin] 取り込んだら .base の行を更新: bin/plugin.sh template add をやり直すか、sha を書き換える"
        ;;
      list)
        [ -f "$tbase" ] && sed 's/^[0-9a-f]*  /  /' "$tbase" || echo "[plugin] 写しはありません"
        ;;
      *) die "使い方: bin/plugin.sh template {add <Code> <相対パス> | diff | list}" ;;
    esac
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
