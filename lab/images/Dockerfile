# syntax=docker/dockerfile:1
#
# Laboratorio STFC do flux-loadtest (WEB-1437). Um estagio por tipo de servidor.
# Todos em Debian 12, como em producao.

# ------------------------------------------------------------------ base
FROM debian:12 AS base
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-server sudo iproute2 procps curl ca-certificates tini less \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /etc/flux-lab \
    && useradd -m -s /bin/bash loadtest \
    && useradd -m -s /bin/bash -G sudo admin
COPY common/ /opt/flux-lab/
RUN chmod 0755 /opt/flux-lab/entrypoint.sh
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/flux-lab/entrypoint.sh"]

# ------------------------------------------------------------------ sbc (OpenSIPS e FreeSWITCH simulados)
FROM base AS sbc
ENV LAB_ROLE=sbc
RUN apt-get update \
    && apt-get install -y --no-install-recommends sip-tester \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/sipp /usr/local/sbin/freeswitch \
    && ln -s /usr/bin/sipp /usr/local/sbin/opensips \
    && mkdir -p /var/lib/freeswitch /run/flux-lab
COPY sbc/ /opt/flux-lab/sbc/
RUN install -m 0755 /opt/flux-lab/sbc/fs_cli /usr/bin/fs_cli \
    && install -m 0755 /opt/flux-lab/sbc/opensips-cli /usr/bin/opensips-cli \
    && chmod 0755 /opt/flux-lab/sbc/start.sh \
    && printf 'loadtest ALL=(root) NOPASSWD: /usr/bin/fs_cli, /usr/bin/opensips-cli\n' > /etc/sudoers.d/flux-loadtest \
    && chmod 0440 /etc/sudoers.d/flux-loadtest

# ------------------------------------------------------------------ sbc-real (FreeSWITCH + OpenSIPS reais, stack Flux)
# FreeSWITCH 1.11.3 (pacotes SignalWire, como o flux_install.sh), OpenSIPS 3.6, PHP-FPM 7.3 +
# nginx em 127.0.0.1:8735 (xml_curl do Flux) e ODBC para o dialplan Lua. Os scripts do Flux
# vem do clone do repositorio sbc montado em /opt/flux-src (LAB_FLUX_SRC no .env).
# O token da SignalWire entra so como secret do BuildKit: o auth.conf e criado e apagado no
# mesmo RUN, entao nenhuma camada guarda o token. Build: lab.sh up (LAB_SIGNALWIRE_TOKEN_FILE).
FROM base AS sbc-real
ENV LAB_ROLE=sbc-real
ARG OPENSIPS_SERIES=3.6
RUN --mount=type=secret,id=signalwire_token,required=true \
    set -eu \
    && apt-get update \
    && apt-get install -y --no-install-recommends gnupg wget lsb-release \
    && token=$(head -n 1 /run/secrets/signalwire_token | tr -d '[:space:]') \
    && [ -n "${token}" ] \
    && install -m 0600 /dev/null /etc/apt/auth.conf.d/signalwire.conf \
    && printf 'machine freeswitch.signalwire.com login signalwire password %s\n' "${token}" \
        > /etc/apt/auth.conf.d/signalwire.conf \
    && wget -q --http-user=signalwire --http-password="${token}" \
        -O /usr/share/keyrings/signalwire-freeswitch-repo.gpg \
        https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg \
    && unset token \
    && echo "deb [signed-by=/usr/share/keyrings/signalwire-freeswitch-repo.gpg] https://freeswitch.signalwire.com/repo/deb/debian-release/ bookworm main" \
        > /etc/apt/sources.list.d/freeswitch.list \
    && curl -fsSLo /usr/share/keyrings/opensips-org.gpg https://apt.opensips.org/opensips-org.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/opensips-org.gpg] https://apt.opensips.org bookworm ${OPENSIPS_SERIES}-releases" \
        > /etc/apt/sources.list.d/opensips.list \
    && curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && apt-get install -y /tmp/debsuryorg-archive-keyring.deb \
    && rm -f /tmp/debsuryorg-archive-keyring.deb \
    && echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
        > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        freeswitch freeswitch-conf-vanilla freeswitch-mod-console freeswitch-mod-logfile \
        freeswitch-mod-xml-curl freeswitch-mod-json-cdr freeswitch-mod-hash freeswitch-mod-event-socket \
        freeswitch-mod-sofia freeswitch-mod-commands freeswitch-mod-dptools freeswitch-mod-voicemail \
        freeswitch-mod-db freeswitch-mod-dialplan-xml freeswitch-mod-g723-1 freeswitch-mod-sndfile \
        freeswitch-mod-native-file freeswitch-mod-local-stream freeswitch-mod-tone-stream \
        freeswitch-mod-lua freeswitch-mod-say-en freeswitch-sounds-en-us-callie \
        freeswitch-music-default \
        opensips opensips-mysql-module opensips-mysql-dbschema opensips-http-modules opensips-cli \
        nginx php7.3-fpm php7.3-mysql php7.3-cli php7.3-curl php7.3-xml php7.3-mbstring \
        unixodbc odbc-mariadb default-mysql-client sngrep netcat-openbsd \
    && rm -f /etc/apt/auth.conf.d/signalwire.conf /etc/apt/sources.list.d/freeswitch.list \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default \
    && mkdir -p /var/lib/flux /var/log/flux /run/opensips /var/lib/freeswitch \
    && rm -rf /etc/freeswitch \
    && cp -a /usr/share/freeswitch/conf/vanilla /etc/freeswitch
COPY sbc-real/ /opt/flux-lab/sbc-real/
RUN chmod 0755 /opt/flux-lab/sbc-real/start.sh \
    && printf 'loadtest ALL=(root) NOPASSWD: /usr/bin/fs_cli, /usr/bin/opensips-cli\n' > /etc/sudoers.d/flux-loadtest \
    && chmod 0440 /etc/sudoers.d/flux-loadtest

# ------------------------------------------------------------------ db (Percona XtraDB Cluster 8.4.10 + keepalived)
FROM base AS db
ENV LAB_ROLE=db
ARG PXC_VERSION=1:8.4.10-10-1.bookworm
RUN apt-get update \
    && apt-get install -y --no-install-recommends gnupg lsb-release keepalived netcat-openbsd \
    && curl -fsSLo /tmp/percona-release.deb https://repo.percona.com/apt/percona-release_latest.bookworm_all.deb \
    && apt-get install -y /tmp/percona-release.deb \
    && rm -f /tmp/percona-release.deb \
    && percona-release setup -y pxc-84-lts \
    && printf 'Package: percona-xtradb-cluster*\nPin: version %s\nPin-Priority: 1001\n' "${PXC_VERSION}" \
        > /etc/apt/preferences.d/pxc-lab \
    && printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 0755 /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y percona-xtradb-cluster \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /var/lib/mysql/* \
    && mkdir -p /var/run/mysqld /var/log/mysql \
    && chown mysql:mysql /var/run/mysqld /var/log/mysql /var/lib/mysql
COPY db/ /opt/flux-lab/db/
RUN chmod 0755 /opt/flux-lab/db/start.sh

# ------------------------------------------------------------------ web (nginx 1.22.1 + PHP-FPM 7.3.33)
FROM base AS web
ENV LAB_ROLE=web
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx openssl lsb-release \
    && curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && apt-get install -y /tmp/debsuryorg-archive-keyring.deb \
    && rm -f /tmp/debsuryorg-archive-keyring.deb \
    && echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
        > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends php7.3-fpm php7.3-mysql \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default \
    && openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=sbc-stfc-interfaceweb" \
        -keyout /etc/nginx/lab.key -out /etc/nginx/lab.crt
COPY web/ /opt/flux-lab/web/
RUN chmod 0755 /opt/flux-lab/web/start.sh \
    && install -d /var/www/flux/assets/images \
    && cp /opt/flux-lab/web/index.php /var/www/flux/index.php \
    && head -c 4096 /dev/urandom > /var/www/flux/assets/images/addon_icon.png \
    && cp /opt/flux-lab/web/flux.conf /etc/nginx/sites-enabled/flux.conf \
    && cp /opt/flux-lab/web/pool-lab.conf /etc/php/7.3/fpm/pool.d/zz-lab.conf

# ------------------------------------------------------------------ vm-teste (VM originadora)
FROM debian:12 AS gen
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        sip-tester wrk sysbench default-mysql-client python3 openssh-client curl \
        iproute2 procps ca-certificates tini less expect sshpass netbase \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/flux-loadtest /var/lib/flux-loadtest/results
ENTRYPOINT ["/usr/bin/tini", "--", "sleep", "infinity"]
