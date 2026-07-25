# syntax=docker/dockerfile:1

# PHP のバージョン（EC-CUBE 4.1〜4.3 は 8.1〜8.3 で動く。既定 8.2）
ARG PHP_VERSION=8.2
FROM php:${PHP_VERSION}-fpm-bookworm

# EC-CUBE のバージョン制約（composer create-project 用）。compose から渡す。
ARG ECCUBE_VERSION=~4.3.0

# ---- システム依存パッケージ ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        unzip \
        vim \
        libicu-dev \
        libzip-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        libwebp-dev \
        libonig-dev \
        default-mysql-client \
        openssh-client \
        gettext-base \
        libfcgi-bin \
    && rm -rf /var/lib/apt/lists/*

# ---- PHP 拡張 ----
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        mysqli \
        gd \
        intl \
        zip \
        mbstring \
        bcmath \
        exif \
        opcache

# ---- phpredis（セッション/キャッシュの Redis 共有用）----
# バージョンを 6.0.x に固定する。phpredis 6.1+ は hSet が可変長シグネチャに変わり、
# EC-CUBE 4.3 同梱の Symfony Cache 6.4 の Redis6Proxy（3固定引数）と衝突するため。
# pecl のビルドに必要な依存は一時的に入れて、ビルド後に取り除く。
ARG PHPREDIS_VERSION=6.0.2
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
    pecl install "redis-${PHPREDIS_VERSION}"; \
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
