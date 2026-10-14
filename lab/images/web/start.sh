#!/usr/bin/env bash
#
# nginx 1.22.1 + PHP-FPM 7.3.33. A pagina PHP usa o banco pelo VIP 172.30.4.100.

set -Eeuo pipefail

log() { printf '[%(%H:%M:%S)T] %s: %s\n' -1 "$(hostname)" "$*"; }

: "${LAB_WEB_DB_PASSWORD:?defina no .env}"

install -m 0640 -o root -g www-data /dev/null /etc/flux-lab/web-db.ini
printf 'host=172.30.4.100\nport=3306\nuser=flux_web\npassword=%s\ndatabase=flux\n' \
    "${LAB_WEB_DB_PASSWORD}" > /etc/flux-lab/web-db.ini

mkdir -p /run/php
php-fpm7.3 -D
nginx
log "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}') e PHP-FPM $(php-fpm7.3 -v | awk 'NR == 1 { print $2 }') ativos"
