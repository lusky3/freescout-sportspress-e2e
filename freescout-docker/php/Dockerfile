FROM php:8.2-fpm

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Package versions are deliberately unpinned: this is a disposable local
# dev/test harness (see docker-compose.yml's own warning banner), the base
# image itself floats on 8.2-fpm's latest patch, and pinning exact apt
# versions against a moving Debian snapshot would be brittle busywork for a
# container nobody runs in production.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip libzip-dev libpng-dev libonig-dev libxml2-dev libicu-dev default-mysql-client \
    && docker-php-ext-install pdo_mysql zip gd mbstring xml intl bcmath \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
