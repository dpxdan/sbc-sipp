#!/usr/bin/env bash
#
# Papel sbc: FreeSWITCH 1.11.3 (SignalWire) com a stack Flux e, no sbc-stfc-1, o OpenSIPS 3.6.
# Pacotes iguais ao estagio sbc-real do lab/images/Dockerfile; a configuracao e a do
# lab/images/sbc-real/start.sh, executado aqui com LAB_INIT=systemd.
#
# Token da SignalWire: lido do stdin, so na primeira instalacao do FreeSWITCH. Fica num
# auth.conf 0600 durante o apt e e apagado em seguida (nenhum arquivo guarda o token).
#
# role.env: LAB_SIP_ROLES ("fs" ou "fs opensips"), LAB_PUB_IP, LAB_INT_IP, LAB_DB_VIP,
#           LAB_GEN_IP, LAB_FS_PUB_IPS, LAB_FS_INT_IPS, LAB_FLUX_DB_PASSWORD,
#           LAB_FS_CLI_PASSWORD, LAB_RTP_START, LAB_RTP_END, LAB_DEV_PROFILE

# shellcheck source=lab/vm/roles/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly OPENSIPS_SERIES=3.6
readonly SW_AUTH=/etc/apt/auth.conf.d/signalwire.conf

require_root
require_debian12
load_role_env
need LAB_SIP_ROLES LAB_PUB_IP LAB_INT_IP LAB_DB_VIP LAB_GEN_IP LAB_FS_PUB_IPS LAB_FS_INT_IPS \
     LAB_FLUX_DB_PASSWORD LAB_FS_CLI_PASSWORD

cleanup_token() { rm -f "${SW_AUTH}"; }

add_signalwire() {
    local token=""
    # o token vem pelo stdin do SSH (vmlab.sh); nunca por argumento
    if [[ ! -t 0 ]]; then
        IFS= read -r token || true
    fi
    token=$(tr -d '[:space:]' <<< "${token}")
    [[ -n ${token} ]] || die "token da SignalWire nao recebido no stdin (SIGNALWIRE_TOKEN_FILE no vmlab.conf)"
    trap cleanup_token EXIT
    install -m 0600 /dev/null "${SW_AUTH}"
    printf 'machine freeswitch.signalwire.com login signalwire password %s\n' "${token}" > "${SW_AUTH}"
    curl -fsS --netrc-file "${SW_AUTH}" -o /usr/share/keyrings/signalwire-freeswitch-repo.gpg \
        https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg \
        || die "download da chave da SignalWire falhou (token invalido?)"
    unset token
    echo "deb [signed-by=/usr/share/keyrings/signalwire-freeswitch-repo.gpg] https://freeswitch.signalwire.com/repo/deb/debian-release/ bookworm main" \
        > /etc/apt/sources.list.d/freeswitch.list
}

install_packages() {
    local need_fs=0
    dpkg -s freeswitch >/dev/null 2>&1 || need_fs=1
    apt-get update
    apt_install gnupg wget curl lsb-release
    ((need_fs)) && add_signalwire
    if [[ ! -f /etc/apt/sources.list.d/opensips.list ]]; then
        curl -fsSLo /usr/share/keyrings/opensips-org.gpg https://apt.opensips.org/opensips-org.gpg
        echo "deb [signed-by=/usr/share/keyrings/opensips-org.gpg] https://apt.opensips.org bookworm ${OPENSIPS_SERIES}-releases" \
            > /etc/apt/sources.list.d/opensips.list
    fi
    add_sury_php
    apt_install \
        freeswitch freeswitch-conf-vanilla freeswitch-mod-console freeswitch-mod-logfile \
        freeswitch-mod-xml-curl freeswitch-mod-json-cdr freeswitch-mod-hash freeswitch-mod-event-socket \
        freeswitch-mod-sofia freeswitch-mod-commands freeswitch-mod-dptools freeswitch-mod-voicemail \
        freeswitch-mod-db freeswitch-mod-dialplan-xml freeswitch-mod-g723-1 freeswitch-mod-sndfile \
        freeswitch-mod-native-file freeswitch-mod-local-stream freeswitch-mod-tone-stream \
        freeswitch-mod-lua freeswitch-mod-say-en freeswitch-sounds-en-us-callie \
        freeswitch-music-default \
        opensips opensips-mysql-module opensips-mysql-dbschema opensips-http-modules opensips-cli \
        nginx php7.3-fpm php7.3-mysql php7.3-cli php7.3-curl php7.3-xml php7.3-mbstring \
        unixodbc odbc-mariadb default-mysql-client sngrep netcat-openbsd
    if ((need_fs)); then
        # como o Dockerfile: sem o repositorio (e o token) depois da instalacao
        cleanup_token
        rm -f /etc/apt/sources.list.d/freeswitch.list
        trap - EXIT
        apt-get update >/dev/null 2>&1 || true
    fi
}

prepare_system() {
    rm -f /etc/nginx/sites-enabled/default
    install -d -m 0755 /var/lib/flux /var/log/flux /var/lib/freeswitch
    # configuracao vanilla do pacote como base (uma vez), como no Dockerfile
    if [[ ! -f /etc/freeswitch/.flux-lab ]]; then
        rm -rf /etc/freeswitch
        cp -a /usr/share/freeswitch/conf/vanilla /etc/freeswitch
        touch /etc/freeswitch/.flux-lab
    fi
    printf 'loadtest ALL=(root) NOPASSWD: /usr/bin/fs_cli, /usr/bin/opensips-cli\n' > /etc/sudoers.d/flux-loadtest
    chmod 0440 /etc/sudoers.d/flux-loadtest
    visudo -cf /etc/sudoers.d/flux-loadtest >/dev/null || die "sudoers invalido"
    # fs_cli do root sem -p (senha do event socket em arquivo 0600)
    install -m 0600 /dev/null /root/.fs_cli_conf
    printf '[default]\npassword => %s\n' "${LAB_FS_CLI_PASSWORD}" > /root/.fs_cli_conf
    # OpenSIPS so onde o papel pede (o pacote vem instalado nos dois SBC)
    if [[ " ${LAB_SIP_ROLES} " != *" opensips "* ]]; then
        systemctl disable --now opensips >/dev/null 2>&1 || true
    fi
    [[ -d /opt/flux-src/freeswitch ]] || die "/opt/flux-src ausente (o vmlab.sh envia o clone do repositorio sbc)"
}

install_packages
prepare_system
LAB_INIT=systemd LAB_MAC_SOCKETS=0 LAB_TEMPLATE_DIR="${LAB_ROOT}/images/sbc-real" \
    LAB_DEV_PROFILE="${LAB_DEV_PROFILE:-lab-dev}" \
    bash "${LAB_ROOT}/images/sbc-real/start.sh" < /dev/null
log "papel sbc pronto (${LAB_SIP_ROLES})"
