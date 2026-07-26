#!/usr/bin/env bash
# ユニットテストを実行する（app/Customize/Tests/ を対象、phpunit.xml を使用）。
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
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose exec -T -e APP_ENV=test -e APP_DEBUG=0 ec-cube runuser -u www-data -- \
    php vendor/bin/phpunit -c phpunit.xml "$@"
