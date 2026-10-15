#!/usr/bin/env bash
#
# Papel db: Percona XtraDB Cluster 8.4.10 + keepalived (VIP), como no lab Docker
# (lab/images/db/start.sh), com unidades systemd.
#   no 1: inicializa o datadir e faz o bootstrap (mysql@bootstrap); cria schemas e usuarios
#   no 2: entra no cluster por SST (mysql)
#   "db.sh normalize" no no 1: depois do no 2 Synced, troca o mysql@bootstrap pelo mysql
#
# Na primeira execucao o datadir do no e recriado; o script recusa se ja existir o schema
# flux nele (dados que nao sao do laboratorio ficam intactos).
#
# role.env: LAB_DB_NODE (1|2), LAB_DB_ADDR, LAB_DB_PEER, LAB_CLUSTER_ADDR, LAB_DB_VIP,
#           LAB_DB_VIP_PREFIX, LAB_VRRP_ROUTER_ID, LAB_VRRP_PRIORITY, LAB_NET_PATTERN,
#           LAB_MONITOR_PASSWORD, LAB_BENCH_PASSWORD, LAB_WEB_DB_PASSWORD

# shellcheck source=lab/vm/roles/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly PXC_VERSION=1:8.4.10-10-1.bookworm
readonly MARKER=/etc/flux-lab/db-initialized
readonly SOCK=/var/run/mysqld/mysqld.sock

require_root
require_debian12
load_role_env
need LAB_DB_NODE LAB_DB_ADDR LAB_DB_PEER LAB_CLUSTER_ADDR LAB_DB_VIP LAB_VRRP_PRIORITY \
     LAB_NET_PATTERN LAB_MONITOR_PASSWORD LAB_BENCH_PASSWORD LAB_WEB_DB_PASSWORD
[[ ${LAB_DB_NODE} == 1 || ${LAB_DB_NODE} == 2 ]] || die "LAB_DB_NODE deve ser 1 ou 2"
[[ ${LAB_NET_PATTERN} =~ ^[0-9.%]+$ ]] || die "LAB_NET_PATTERN invalido: ${LAB_NET_PATTERN}"
LAB_DB_VIP_PREFIX=${LAB_DB_VIP_PREFIX:-24}
LAB_VRRP_ROUTER_ID=${LAB_VRRP_ROUTER_ID:-61}

wait_sock() {
    local i
    for ((i = 0; i < 600; i++)); do
        mysqladmin --socket="${SOCK}" ping >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

wsrep_state() {
    mysql -N -B -e "SHOW GLOBAL STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{ print $2 }'
}

install_pxc() {
    if dpkg -s percona-xtradb-cluster >/dev/null 2>&1; then
        return 0
    fi
    log "instalando Percona XtraDB Cluster ${PXC_VERSION}"
    local tmp
    tmp=$(mktemp -d)
    curl -fsSLo "${tmp}/percona-release.deb" https://repo.percona.com/apt/percona-release_latest.bookworm_all.deb
    apt-get install -y "${tmp}/percona-release.deb"
    rm -rf "${tmp}"
    percona-release setup -y pxc-84-lts
    printf 'Package: percona-xtradb-cluster*\nPin: version %s\nPin-Priority: 1001\n' "${PXC_VERSION}" \
        > /etc/apt/preferences.d/pxc-lab
    # sem subir o mysqld com a configuracao padrao (ele faria um cluster sozinho)
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 0755 /usr/sbin/policy-rc.d
    apt-get update
    apt-get install -y percona-xtradb-cluster socat || { rm -f /usr/sbin/policy-rc.d; die "falha na instalacao do PXC"; }
    rm -f /usr/sbin/policy-rc.d
    systemctl stop mysql >/dev/null 2>&1 || true
}

write_config() {
    local provider conf_dir
    provider=$(find /usr/lib -name libgalera_smm.so 2>/dev/null | head -n 1)
    [[ -n ${provider} ]] || die "libgalera_smm.so nao encontrada"
    conf_dir=/etc/mysql/mysql.conf.d
    [[ -d ${conf_dir} ]] || conf_dir=/etc/mysql/conf.d
    sed -e "s|@SERVER_ID@|${LAB_DB_NODE}|" -e "s|@WSREP_PROVIDER@|${provider}|" \
        -e "s|@NODE_ADDR@|${LAB_DB_ADDR}|" -e "s|@NODE_NAME@|$(hostname)|" \
        -e "s|@CLUSTER_ADDR@|${LAB_CLUSTER_ADDR}|" \
        "${LAB_ROOT}/images/db/zz-lab.cnf.in" > "${conf_dir}/zz-lab.cnf"
    install -d -o mysql -g mysql /var/run/mysqld /var/log/mysql
    # credencial da coleta (somente leitura), lida pelo usuario SSH loadtest
    install -m 0600 -o loadtest -g loadtest /dev/null /etc/mysql/flux-loadtest.cnf
    printf '[client]\nuser=flux_monitor\npassword=%s\nsocket=%s\n' "${LAB_MONITOR_PASSWORD}" "${SOCK}" \
        > /etc/mysql/flux-loadtest.cnf
}

# Datadir novo; recusa se houver o schema flux (dados de verdade ficam intactos)
reset_datadir() {
    [[ ! -d /var/lib/mysql/flux ]] \
        || die "/var/lib/mysql ja tem o schema flux; apague manualmente se for mesmo um laboratorio"
    find /var/lib/mysql -mindepth 1 -delete
    chown mysql:mysql /var/lib/mysql
}

bootstrap_node1() {
    log "inicializando o datadir e fazendo o bootstrap do cluster"
    reset_datadir
    mysqld --initialize-insecure --user=mysql >/dev/null 2>&1 || die "mysqld --initialize falhou (/var/log/mysql/error.log)"
    systemctl start mysql@bootstrap.service || die "bootstrap falhou (journalctl -u mysql@bootstrap)"
    wait_sock || die "mysqld nao respondeu"
    # root so pelo socket (auth_socket, carregado pelo zz-lab.cnf): o vmlab.sh usa "sudo mysql"
    mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;
CREATE USER IF NOT EXISTS 'flux_monitor'@'localhost' IDENTIFIED BY '${LAB_MONITOR_PASSWORD}';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'flux_monitor'@'localhost';
CREATE DATABASE IF NOT EXISTS flux;
CREATE TABLE IF NOT EXISTS flux.ci_sessions (
    session_id    VARCHAR(40) NOT NULL PRIMARY KEY,
    ip_address    VARCHAR(45) NOT NULL DEFAULT '0',
    user_agent    VARCHAR(120) NOT NULL,
    last_activity INT UNSIGNED NOT NULL DEFAULT 0,
    user_data     TEXT
) ENGINE=InnoDB;
CREATE USER IF NOT EXISTS 'flux_web'@'${LAB_NET_PATTERN}' IDENTIFIED WITH mysql_native_password BY '${LAB_WEB_DB_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE ON flux.* TO 'flux_web'@'${LAB_NET_PATTERN}';
CREATE DATABASE IF NOT EXISTS loadtest;
CREATE USER IF NOT EXISTS 'flux_bench'@'${LAB_NET_PATTERN}' IDENTIFIED BY '${LAB_BENCH_PASSWORD}';
GRANT ALL ON loadtest.* TO 'flux_bench'@'${LAB_NET_PATTERN}';
CREATE USER IF NOT EXISTS 'labcheck'@'localhost' IDENTIFIED WITH auth_socket AS 'root';
GRANT SELECT ON flux.* TO 'labcheck'@'localhost';
GRANT SELECT ON loadtest.* TO 'labcheck'@'localhost';
SQL
    log "schemas e usuarios criados"
}

join_node2() {
    local attempt i
    for attempt in 1 2 3; do
        log "aguardando o no 1 (${LAB_DB_PEER}:3306)"
        wait_tcp "${LAB_DB_PEER}" 3306 300 || die "no 1 nao aceita conexoes em ${LAB_DB_PEER}:3306"
        log "entrando no cluster (SST, tentativa ${attempt}/3)"
        systemctl stop mysql >/dev/null 2>&1 || true
        reset_datadir
        if systemctl start mysql && wait_sock; then
            for ((i = 0; i < 120; i++)); do
                [[ $(wsrep_state) == Synced ]] && return 0
                sleep 2
            done
        fi
        warn "SST nao concluiu (journalctl -u mysql, /var/log/mysql/error.log); nova tentativa em 15 s"
        systemctl stop mysql >/dev/null 2>&1 || true
        sleep 15
    done
    die "no 2 nao entrou no cluster apos 3 tentativas"
}

# Execucoes seguintes: garante o mysqld no ar sem recriar dados
ensure_running() {
    if systemctl is-active --quiet mysql || systemctl is-active --quiet mysql@bootstrap; then
        return 0
    fi
    if [[ ${LAB_DB_NODE} == 2 ]] || wait_tcp "${LAB_DB_PEER}" 4567 5; then
        systemctl start mysql || die "mysql nao subiu (journalctl -u mysql)"
    elif grep -q '^safe_to_bootstrap: 1' /var/lib/mysql/grastate.dat 2>/dev/null; then
        log "cluster parado e este no e seguro para bootstrap"
        systemctl start mysql@bootstrap.service || die "bootstrap falhou"
    else
        die "cluster parado: faca o bootstrap pelo no com safe_to_bootstrap: 1 (systemctl start mysql@bootstrap)"
    fi
    wait_sock || die "mysqld nao respondeu"
}

setup_keepalived() {
    local iface
    iface=$(iface_of "${LAB_DB_ADDR}")
    [[ -n ${iface} ]] || die "interface com ${LAB_DB_ADDR} nao encontrada"
    apt_install keepalived
    cat > /etc/keepalived/keepalived.conf <<CONF
global_defs {
    router_id $(hostname)
    script_user root
    enable_script_security
}
vrrp_script chk_mysqld {
    script "/usr/bin/pgrep -x mysqld"
    interval 2
    timeout 5
    fall 3
    rise 2
}
vrrp_instance VI_DB {
    state BACKUP
    interface ${iface}
    virtual_router_id ${LAB_VRRP_ROUTER_ID}
    priority ${LAB_VRRP_PRIORITY}
    advert_int 1
    unicast_src_ip ${LAB_DB_ADDR}
    unicast_peer {
        ${LAB_DB_PEER}
    }
    virtual_ipaddress {
        ${LAB_DB_VIP}/${LAB_DB_VIP_PREFIX} dev ${iface}
    }
    track_script {
        chk_mysqld
    }
}
CONF
    systemctl enable keepalived >/dev/null 2>&1 || true
    systemctl restart keepalived
    log "keepalived ativo (interface ${iface}, prioridade ${LAB_VRRP_PRIORITY}, VIP ${LAB_DB_VIP})"
}

# no 1: sai do mysql@bootstrap e volta como membro comum (o no 2 ja e Synced)
normalize() {
    [[ ${LAB_DB_NODE} == 1 ]] || return 0
    systemctl is-active --quiet mysql@bootstrap || { log "no 1 ja roda como membro comum"; return 0; }
    log "no 1: trocando mysql@bootstrap por mysql"
    systemctl stop mysql@bootstrap.service
    systemctl start mysql || die "mysql nao subiu no no 1 (journalctl -u mysql)"
    wait_sock || die "mysqld nao respondeu"
    log "no 1 de volta ao cluster ($(wsrep_state))"
}

case "${1:-install}" in
    install)
        apt-get update
        apt_install curl gnupg lsb-release netcat-openbsd
        install_pxc
        write_config
        if [[ ! -f ${MARKER} ]]; then
            systemctl stop mysql >/dev/null 2>&1 || true
            if [[ ${LAB_DB_NODE} == 1 ]]; then bootstrap_node1; else join_node2; fi
            date +%s > "${MARKER}"
        else
            ensure_running
        fi
        systemctl enable mysql >/dev/null 2>&1 || true
        setup_keepalived
        log "papel db pronto (no ${LAB_DB_NODE}, $(wsrep_state))"
        ;;
    normalize) normalize ;;
    *) die "uso: db.sh [install|normalize]" ;;
esac
