#!/usr/bin/env bash
#
# Percona XtraDB Cluster 8.4.10 + keepalived (VIP 172.30.4.100).
#   no 1 (banco-master-sbc-stfc): inicializa e faz o bootstrap do cluster; cria
#         schemas e usuarios (replicados para o no 2 pelo wsrep)
#   no 2 (banco-slave-stfc): entra no cluster por SST
# Dados efemeros: cada "lab.sh up" comeca do zero.

set -Eeuo pipefail

log() { printf '[%(%H:%M:%S)T] %s: %s\n' -1 "$(hostname)" "$*"; }

: "${LAB_DB_NODE:?}" "${LAB_DB_ADDR:?}" "${LAB_DB_PEER:?}" "${LAB_VRRP_PRIORITY:?}"
: "${LAB_MYSQL_ROOT_PASSWORD:?}" "${LAB_MONITOR_PASSWORD:?}" "${LAB_BENCH_PASSWORD:?}" "${LAB_WEB_DB_PASSWORD:?}"
VIP=172.30.4.100

provider=$(find /usr/lib -name libgalera_smm.so 2>/dev/null | head -n 1)
[[ -n ${provider} ]] || { log "libgalera_smm.so nao encontrada"; exit 1; }

conf_dir=/etc/mysql/mysql.conf.d
[[ -d ${conf_dir} ]] || conf_dir=/etc/mysql/conf.d
sed -e "s|@SERVER_ID@|${LAB_DB_NODE}|" -e "s|@WSREP_PROVIDER@|${provider}|" \
    -e "s|@NODE_ADDR@|${LAB_DB_ADDR}|" -e "s|@NODE_NAME@|$(hostname)|" \
    /opt/flux-lab/db/zz-lab.cnf.in > "${conf_dir}/zz-lab.cnf"

# Credencial da coleta (usuario somente leitura), lida pelo usuario SSH loadtest
install -m 0600 -o loadtest -g loadtest /dev/null /etc/mysql/flux-loadtest.cnf
printf '[client]\nuser=flux_monitor\npassword=%s\nsocket=/var/run/mysqld/mysqld.sock\n' \
    "${LAB_MONITOR_PASSWORD}" > /etc/mysql/flux-loadtest.cnf

wait_sock() {
    local i
    for ((i = 0; i < 180; i++)); do
        mysqladmin --socket=/var/run/mysqld/mysqld.sock ping >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

if [[ ${LAB_DB_NODE} == 1 ]]; then
    log "inicializando o datadir"
    mysqld --initialize-insecure --user=mysql >/dev/null 2>&1
    log "bootstrap do cluster"
    mysqld --user=mysql --wsrep-new-cluster &
    wait_sock || { log "mysqld nao subiu; veja /var/log/mysql/error.log"; exit 1; }
    mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${LAB_MYSQL_ROOT_PASSWORD}';
CREATE USER 'flux_monitor'@'localhost' IDENTIFIED BY '${LAB_MONITOR_PASSWORD}';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'flux_monitor'@'localhost';
CREATE DATABASE flux;
CREATE TABLE flux.ci_sessions (
    session_id    VARCHAR(40) NOT NULL PRIMARY KEY,
    ip_address    VARCHAR(45) NOT NULL DEFAULT '0',
    user_agent    VARCHAR(120) NOT NULL,
    last_activity INT UNSIGNED NOT NULL DEFAULT 0,
    user_data     TEXT
) ENGINE=InnoDB;
CREATE USER 'flux_web'@'172.30.4.%' IDENTIFIED WITH mysql_native_password BY '${LAB_WEB_DB_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE ON flux.* TO 'flux_web'@'172.30.4.%';
CREATE DATABASE loadtest;
CREATE USER 'flux_bench'@'172.30.%' IDENTIFIED BY '${LAB_BENCH_PASSWORD}';
GRANT ALL ON loadtest.* TO 'flux_bench'@'172.30.%';
CREATE USER 'labcheck'@'localhost' IDENTIFIED WITH auth_socket AS 'root';
GRANT SELECT ON flux.* TO 'labcheck'@'localhost';
GRANT SELECT ON loadtest.* TO 'labcheck'@'localhost';
SQL
    log "schemas e usuarios criados"
else
    log "aguardando o no 1 (${LAB_DB_PEER}:4567)"
    for ((i = 0; i < 300; i++)); do
        nc -z "${LAB_DB_PEER}" 4567 2>/dev/null && break
        sleep 1
    done
    sleep 5
    log "entrando no cluster (SST)"
    mysqld --user=mysql &
    wait_sock || { log "mysqld nao subiu; veja /var/log/mysql/error.log"; exit 1; }
fi
log "mysqld ativo"

# keepalived: VIP no no de maior prioridade com o mysqld vivo
iface=$(ip -o -4 addr show | awk -v a="${LAB_DB_ADDR}/" 'index($4, a) == 1 { print $2; exit }')
cat > /etc/keepalived/keepalived.conf <<CONF
global_defs {
    router_id $(hostname)
    script_user root
    enable_script_security
}
vrrp_script chk_mysqld {
    script "/usr/bin/pgrep -x mysqld"
    interval 2
    # Tolerante a CPU disputada (o Docker do laboratorio divide poucas vCPUs entre
    # os 6 containers): sem isso o VIP oscila sob carga.
    timeout 5
    fall 3
    rise 2
}
vrrp_instance VI_DB {
    state BACKUP
    interface ${iface}
    virtual_router_id 61
    priority ${LAB_VRRP_PRIORITY}
    advert_int 1
    unicast_src_ip ${LAB_DB_ADDR}
    unicast_peer {
        ${LAB_DB_PEER}
    }
    virtual_ipaddress {
        ${VIP}/24 dev ${iface}
    }
    track_script {
        chk_mysqld
    }
}
CONF
keepalived -f /etc/keepalived/keepalived.conf
log "keepalived ativo (interface ${iface}, prioridade ${LAB_VRRP_PRIORITY})"
