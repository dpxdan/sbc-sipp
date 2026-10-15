#!/usr/bin/env bash
#
# Papel web: nginx 1.22.1 + PHP-FPM 7.3 (sury), vhost e pool do lab Docker
# (lab/images/web), pagina PHP com sessao no banco pelo VIP. Idempotente.
#
# role.env: LAB_DB_VIP, LAB_WEB_DB_PASSWORD

# shellcheck source=lab/vm/roles/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly SRC="${LAB_ROOT}/images/web"

require_root
require_debian12
load_role_env
need LAB_DB_VIP LAB_WEB_DB_PASSWORD

apt-get update
apt_install nginx openssl curl lsb-release
add_sury_php
apt_install php7.3-fpm php7.3-mysql

rm -f /etc/nginx/sites-enabled/default
if [[ ! -s /etc/nginx/lab.key ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=$(hostname)" \
        -keyout /etc/nginx/lab.key -out /etc/nginx/lab.crt 2>/dev/null
    chmod 0600 /etc/nginx/lab.key
fi
install -d /var/www/flux/assets/images /etc/flux-lab
install -m 0644 "${SRC}/index.php" /var/www/flux/index.php
[[ -s /var/www/flux/assets/images/addon_icon.png ]] || head -c 4096 /dev/urandom > /var/www/flux/assets/images/addon_icon.png
install -m 0644 "${SRC}/flux.conf" /etc/nginx/sites-enabled/flux.conf
install -m 0644 "${SRC}/pool-lab.conf" /etc/php/7.3/fpm/pool.d/zz-lab.conf

install -m 0640 -o root -g www-data /dev/null /etc/flux-lab/web-db.ini
printf 'host=%s\nport=3306\nuser=flux_web\npassword=%s\ndatabase=flux\n' "${LAB_DB_VIP}" "${LAB_WEB_DB_PASSWORD}" \
    > /etc/flux-lab/web-db.ini

nginx -t 2>/dev/null || die "configuracao do nginx invalida (nginx -t)"
systemctl enable php7.3-fpm nginx >/dev/null 2>&1 || true
systemctl restart php7.3-fpm nginx
log "papel web pronto: nginx $(nginx -v 2>&1 | awk -F/ '{print $2}'), PHP-FPM $(php-fpm7.3 -v | awk 'NR == 1 { print $2 }')"
