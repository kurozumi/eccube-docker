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

# ---- Composer ----
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# ---- PHP 設定 ----
COPY docker/php/php.ini /usr/local/etc/php/conf.d/zzz-eccube.ini

WORKDIR /var/www/html

# ---- EC-CUBE 本体をイメージへベイク ----
# 本体はここに焼き込み、リポジトリには含めない（＝バージョン切替＝イメージ再ビルド）。
# DB を要するスクリプトはビルド時に走らせない（--no-scripts）。DB 依存の初期化は
# エントリポイントが起動時に実施する。
RUN composer create-project "ec-cube/ec-cube:${ECCUBE_VERSION}" /var/www/html \
        --no-interaction --no-scripts --prefer-dist \
    && composer clear-cache \
    && chown -R www-data:www-data /var/www/html

# ---- エントリポイント ----
COPY docker/php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
