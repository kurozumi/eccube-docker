#!/usr/bin/env bash
# ユニットテストを実行する（app/Customize/Tests/ を対象）。
#   bin/test.sh                      # 全テスト
#   bin/test.sh --filter testAddition
#   bin/test.sh --testdox
#   bin/test.sh app/Plugin/Foo/Tests # パスを渡せば任意のテストも実行できる
# 追加引数はそのまま phpunit へ渡る。
#
# APP_ENV=test をコンテナのプロセス環境として渡すのが重要。コンテナは既定で
# APP_ENV=prod を持っており、Symfony の KernelTestCase は
# $_ENV/$_SERVER の APP_ENV を先に見るため、phpunit.xml の <server> 指定だけでは
# prod カーネルが起動してしまい、WebTestCase 系が
# 「framework.test config is not set to true」で全部落ちる。
#
# 設定ファイルは EC-CUBE のバージョンによって書式が違うので、コンテナに入っている
# PHPUnit のメジャーバージョンを見て選ぶ（.env の ECCUBE_VERSION ではなく実物を見る。
# 再ビルドや依存解決の結果ズレることがあるため）。
#   PHPUnit 9 以前（EC-CUBE 4.2 / 4.3） → phpunit.xml     … <listeners> / <coverage>
#   PHPUnit 10 以降（EC-CUBE 4.4 〜）   → phpunit.11.xml  … <extensions> / <source>
# 書式が合わない設定を渡しても PHPUnit は警告を出して読み飛ばすだけなので、
# DAMA のロールバックが黙って無効化され、テストが本番と同じ DB を汚し続ける。
# それを防ぐため、選択後に「中身が想定どおりか」「実行時に validation 警告が
# 出ていないか」まで検証する。
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "[test] エラー: $*" >&2; exit 1; }

# 1) コンテナに入っている PHPUnit のメジャーバージョンを取る
version_line="$(docker compose exec -T ec-cube php vendor/bin/phpunit --version 2>/dev/null | head -1 || true)"
major="$(printf '%s' "$version_line" | sed -nE 's/^PHPUnit ([0-9]+)\..*/\1/p')"
[ -n "$major" ] || fail "コンテナの PHPUnit バージョンを判別できませんでした。
       コンテナが起動しているか確認してください（docker compose ps）。"

# 2) メジャーバージョンに対応する設定ファイルを選ぶ
if [ "$major" -ge 10 ]; then
    config=phpunit.11.xml
    want=extension   # <extensions><bootstrap class="...PHPUnitExtension">
else
    config=phpunit.xml
    want=listener    # <listeners><listener class="...PHPUnitListener">
fi
[ -f "$config" ] || fail "$config がありません（PHPUnit ${major} 系にはこの設定が要ります）。"

# 3) コンテナが見ている設定がホストの内容と一致しているか。
#    単一ファイルの bind mount はホスト側で編集すると inode が変わり、コンテナが
#    古い内容を掴んだままになることがある（中途半端な内容で「Premature end of data」等）。
container_size="$(docker compose exec -T ec-cube stat -c %s "/var/www/html/$config" 2>/dev/null | tr -d '\r' || true)"
[ -n "$container_size" ] || fail "コンテナに /var/www/html/$config がありません。
       compose.yaml のマウントを反映するため docker compose up -d --force-recreate ec-cube を実行してください。"
host_size="$(wc -c < "$config" | tr -d ' ')"
[ "$container_size" = "$host_size" ] || fail "$config のホスト（${host_size}B）とコンテナ（${container_size}B）の内容がズレています。
       docker compose up -d --force-recreate ec-cube でマウントを張り直してください。"

# 4) DAMA の登録方法が PHPUnit のメジャーバージョンと噛み合っているか。
#    コンテナが実際に読むファイルを DOM で見る（コメント中の記述に引っかからないため）。
found="$(docker compose exec -T -e PHPUNIT_CFG="/var/www/html/$config" ec-cube php <<'PHP' || true
<?php
$doc = new DOMDocument();
if (!@$doc->load(getenv('PHPUNIT_CFG'))) { echo 'invalid'; exit; }
$xp = new DOMXPath($doc);
$hit = [];
if ($xp->query('/phpunit/listeners/listener[contains(@class, "PHPUnitListener")]')->length) { $hit[] = 'listener'; }
if ($xp->query('/phpunit/extensions/bootstrap[contains(@class, "PHPUnitExtension")]')->length) { $hit[] = 'extension'; }
echo $hit ? implode(',', $hit) : 'none';
PHP
)"
case "$found" in
    "$want") ;;
    invalid) fail "$config を XML として読めません（コンテナ側）。
       ホストで編集した直後なら docker compose up -d --force-recreate ec-cube を試してください。" ;;
    *) fail "$config の DAMA 登録が PHPUnit ${major} 系と噛み合っていません（検出: ${found:-なし}／期待: ${want}）。
       PHPUnit 9 以前は <listeners><listener class=\"...PHPUnitListener\">、
       10 以降は <extensions><bootstrap class=\"...PHPUnitExtension\"> で書きます。
       噛み合わないと読み飛ばされ、ロールバックが効かないまま DB を汚します。" ;;
esac

# 4.5) faker の単語プールが尽きていないか。
#    管理画面の Web テスト（AbstractAdminWebTestCase）はメソッドごとに Member を作るが、
#    Web テストは DAMA でロールバックされず dtb_member に残る。
#    Generator::createMember() は
#      do { $loginId = $faker->word; } while ($memberRepository->findBy(['login_id' => $loginId]));
#    で未使用の login_id を探すため、**残った Member が単語の総数に達すると永久に抜けられない**。
#    エラーもタイムアウトも出ず PHP が CPU を回し続けるだけなので、原因を追うのが非常に難しい
#    （ja_JP の word は 182 語しかなく、実際に 2 回踏んだ）。
#    行は消さずに login_id だけ退避して単語を空ける。creator_id などの参照は壊れない。
pool="$(docker compose exec -T ec-cube php -r '
    require "/var/www/html/vendor/autoload.php";
    $locale = getenv("ECCUBE_LOCALE") ?: "ja_JP";
    $faker = Faker\Factory::create($locale);
    $words = [];
    for ($i = 0; $i < 3000; $i++) { $words[$faker->word] = true; }
    echo count($words);
' 2>/dev/null | tr -cd '0-9' || true)"

leaked_sql="SELECT COUNT(*) AS c FROM dtb_member WHERE id > 2 AND login_id NOT LIKE 'leaked-%'"
leaked="$(docker compose exec -T ec-cube runuser -u www-data -- \
    php bin/console dbal:run-sql "$leaked_sql" 2>/dev/null | grep -Eo '[0-9]+' | tail -1 || true)"

if [ -n "$pool" ] && [ -n "$leaked" ] && [ "$leaked" -ge "$((pool - 20))" ]; then
    echo "[test] テストが残した Member が ${leaked} 件あります（faker の単語は ${pool} 語）。"
    echo "[test] このままだと Generator::createMember() が未使用の login_id を見つけられず、"
    echo "[test] テストがエラーも出さずに固まります。login_id を退避して単語を空けます。"
    docker compose exec -T ec-cube runuser -u www-data -- \
        php bin/console dbal:run-sql \
        "UPDATE dtb_member SET login_id = CONCAT('leaked-', id) WHERE id > 2 AND login_id NOT LIKE 'leaked-%'" \
        >/dev/null 2>&1 || echo "[test] 退避に失敗しました。bin/reset.sh で DB を初期化してください。" >&2
fi

# 5) 実行。設定ファイルの validation 警告が出たら、テストが緑でも失敗扱いにする
#    （警告だけ出して読み飛ばされた要素があると、DAMA が登録されていない可能性がある）。
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

set +e
docker compose exec -T -e APP_ENV=test -e APP_DEBUG=0 ec-cube runuser -u www-data -- \
    php vendor/bin/phpunit -c "$config" "$@" 2>&1 | tee "$out"
status=${PIPESTATUS[0]}
set -e

if grep -q "did not pass validation" "$out"; then
    echo >&2
    fail "$config が PHPUnit ${major} 系の書式として不正です（上の validation 警告を参照）。
       読み飛ばされた要素があるため DAMA のロールバックが効いていない可能性があります。
       テスト結果に関わらず失敗として扱います。"
fi

exit "$status"
