FROM php:8.3-apache AS registration

LABEL org.opencontainers.image.title="tortoise-wow-container-registration" \
      org.opencontainers.image.description="WoWSimpleRegistration web UI for Turtle WoW" \
      org.opencontainers.image.source="https://github.com/dr1s/tortoise-wow-container" \
      org.opencontainers.image.licenses="GPL-3.0"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgmp-dev \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        libzip-dev \
        libxml2-dev \
        zlib1g-dev \
        libonig-dev \
        git \
        curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php \
    && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer \
    && rm -f /tmp/composer-setup.php \
    && cp ${PHP_INI_DIR}/php.ini-production ${PHP_INI_DIR}/php.ini \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gmp gd zip soap mbstring pdo pdo_mysql \
    && a2enmod rewrite

RUN git clone --depth=1 https://github.com/masterking32/WoWSimpleRegistration.git /var/www/html \
    && composer install --no-interaction \
                        --no-dev \
                        --optimize-autoloader \
                        --working-dir=/var/www/html/application

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY render-config.sh /usr/local/bin/render-config.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/render-config.sh

WORKDIR /var/www/html

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["curl", "-fsS", "http://localhost/"]

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
