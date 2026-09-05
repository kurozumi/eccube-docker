# syntax=docker/dockerfile:1

# PHP のバージョン（EC-CUBE 4.1〜4.3 は 8.1〜8.3 で動く。既定 8.2）
ARG PHP_VERSION=8.2
FROM php:${PHP_VERSION}-fpm-bookworm

# EC-CUBE のバージョン制約（composer create-project 用）。compose から渡す。
ARG ECCUBE_VERSION=~4.3.0

# ---- システム依存パッケージ ----
# 本番イメージに載せるのは動かすのに要るものだけ。vim と openssh-client は外した（#111。
# コンテナの中で ssh を使う処理は無く、プラグインの clone はホスト側の bin/plugin.sh がやる）。
# git と composer は残す: 4.4 は `4.4.x-dev` を composer が git で取るのと、古いボリュームに
# messenger を足す経路（docker-entrypoint.sh）が composer を使うため。
# **apt-get upgrade を必ず入れる。** 土台の php:8.x イメージが焼き直されるのを当てにしない。
# PHP 8.1 の土台は EOL（2025-12）で二度と焼き直されず、そのままだと Debian の修正済み CVE が
# 数百件（ほとんど linux-libc-dev）残ったまま毎週配ることになった（v1.0.3 の Trivy で判明）。
# ここで上げれば、毎週の焼き直し（キャッシュ無し）のたびに bookworm の最新パッチが入る。
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        git \
        unzip \
        libicu-dev \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        libwebp-dev \
        libonig-dev \
        default-mysql-client \
        # PostgreSQL（DB_ENGINE=postgresql）。pg_isready を entrypoint の起動待ちに使う
        postgresql-client \
        libpq-dev \
        gettext-base \
        libfcgi-bin \
    && rm -rf /var/lib/apt/lists/*

# ---- PHP 拡張 ----
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        mysqli \
        # PostgreSQL も同じイメージに同居させる（配布タグを DB ごとに増やさない）
        pdo_pgsql \
        gd \
        intl \
        zip \
        mbstring \
        bcmath \
        exif \
    # opcache は **PHP 8.5 から本体に組み込み**で、shared では作れない。8.5 で
    # docker-php-ext-install に渡すと「Build complete」の直後に modules/ が無くて落ちる
    # （cp: cannot stat 'modules/*'）。すでに載っていれば飛ばす
    && if ! php -m | grep -qi '^Zend OPcache'; then docker-php-ext-install -j"$(nproc)" opcache; fi

# ---- phpredis（セッション/キャッシュの Redis 共有用）----
# バージョンは EC-CUBE 側の Symfony Cache に合わせる必要があり、両立しない。
#
#   EC-CUBE 4.2 / 4.3（Symfony Cache 6.4） … 6.0.x
#       phpredis 6.1+ は hSet が可変長シグネチャに変わり、Redis6Proxy（3固定引数）
#       と衝突する。
#   EC-CUBE 4.4（Symfony Cache 7.4）        … 6.1 以上
#       symfony/cache 7.4 が ext-redis <6.1 を conflict に指定している。
#
# 既定は 4.3 向け。切り替えは compose の build arg（.env の PHPREDIS_VERSION）で行う。
# bin/switch-version.sh は ECCUBE_VERSION に応じてこれを自動で設定する。
# pecl のビルドに必要な依存は一時的に入れて、ビルド後に取り除く。
ARG PHPREDIS_VERSION=6.0.2
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
    # pecl.php.net は時々「No releases available」を返す（60 秒待って失敗）。それだけで
    # リリースの 9 通りのビルドが 1 つ落ちるので、3 回まで待って試す
    for i in 1 2 3; do pecl install "redis-${PHPREDIS_VERSION}" && break; [ "$i" = 3 ] && exit 1; sleep 15; done; \
    docker-php-ext-enable redis; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/* /tmp/pear

# ---- Composer ----
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# ---- PHP 設定 ----
COPY docker/php/php.ini /usr/local/etc/php/conf.d/zzz-eccube.ini
# php-fpm プールのテンプレート（entrypoint が env から生成する）
COPY docker/php/www-pool.conf.tmpl /usr/local/etc/php/eccube/www-pool.conf.tmpl

WORKDIR /var/www/html

# ---- EC-CUBE 本体をイメージへベイク ----
# 本体はここに焼き込み、リポジトリには含めない（＝バージョン切替＝イメージ再ビルド）。
# DB を要するスクリプトはビルド時に走らせない（--no-scripts）。DB 依存の初期化は
# エントリポイントが起動時に実施する。
RUN composer create-project "ec-cube/ec-cube:${ECCUBE_VERSION}" /var/www/html \
        --no-interaction --no-scripts --prefer-dist \
    && composer clear-cache \
    && chown -R www-data:www-data /var/www/html

# ---- 同梱のサンプルプラグインを外す ----
# 本体は app/Plugin に EC-CUBE のテスト用サンプルプラグイン（HogePlugin /
# MigrationSample / EntityExtension など）を同梱している。本番向けイメージに
# テスト用フィクスチャを載せる理由が無いうえ、ホストの app/Plugin を bind-mount
# すると隠れてしまい、composer の classmap だけが存在しないファイルを参照して
# 「Failed to open stream」の warning を出し続ける状態になる。
# ここで消し、次段の composer require がオートローダを貼り直す。
# （.gitkeep は * に含まれないので残る）
RUN rm -rf /var/www/html/app/Plugin/* \
    && chown -R www-data:www-data /var/www/html/app/Plugin

# ---- メール非同期化用: Symfony Messenger（本体に未同梱）----
# 注文完了などのメール送信をキュー経由にして SMTP 応答待ち/障害から切り離す。
# 設定は app/config/eccube/packages/messenger.yaml、consumer は compose の worker。
# 本体ソースは編集しない（composer.json への追加のみ。再ビルドで再現される）。
#
# バージョンは固定せず composer に解決させる。EC-CUBE の系列ごとに土台の Symfony が
# 違う（4.2 系 = Symfony 5.4 / 4.3 系 = Symfony 6.4）ため、~6.4.0 のように決め打ちすると
# 4.2 以前のビルドが依存解決に失敗する。
RUN composer require --working-dir=/var/www/html --no-interaction --no-scripts \
        "symfony/messenger:*" "symfony/doctrine-messenger:*" \
    && composer clear-cache \
    && chown -R www-data:www-data /var/www/html/vendor /var/www/html/composer.json /var/www/html/composer.lock

# ---- エントリポイント ----
COPY docker/php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
