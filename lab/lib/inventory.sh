# shellcheck shell=bash
#
# lab/lib/inventory.sh - inventario do laboratorio STFC em VMs Debian 12 (WEB-1437), comum
# ao orquestrador por SSH (lab/vm/vmlab.sh) e ao instalador local (install/flux-host.sh).
#
# Biblioteca para "source": nao altera opcoes do shell. O chamador define antes:
#   log, warn, die           mensagens (die encerra)
#   CONF_FILE                arquivo CHAVE=valor (vmlab.conf ou host.conf)
#   LAB_DIR, REPO_DIR        diretorios lab/ e raiz do repositorio
#   HOSTS                    ids do inventario (sbc1 sbc2 db1 db2 web)
#   root_sql, flux_require_db  usados por cmd_flux (SQL como root no no 1)
# O chamador pode acrescentar chaves a CFG antes de load_config.

declare -A CFG=(
    [SSH_ADMIN_USER]="admin" [SSH_PORT]="22" [GEN_IP]=""
    [HOST_SBC1]="" [HOST_SBC2]="" [HOST_DB1]="" [HOST_DB2]="" [HOST_WEB]=""
    [NAME_SBC1]="sbc-stfc-1" [NAME_SBC2]="sbc-stfc-02" [NAME_DB1]="banco-master-sbc-stfc"
    [NAME_DB2]="banco-slave-stfc" [NAME_WEB]="sbc-stfc-interfaceweb" [SET_HOSTNAME]="1"
    [DB_VIP]="" [DB_VIP_PREFIX]="24" [VRRP_ROUTER_ID]="61" [NET_PATTERN]=""
    [FLUX_GIT_URL]="" [FLUX_GIT_REF]="master" [FLUX_SRC_DIR]="/opt/flux-src" [FLUX_SCRIPTS_DIR]=""
    [SIGNALWIRE_TOKEN_FILE]="/root/.config/flux-lab/signalwire.token"
    [SIP_DEVICES]="20" [DIDS]="100000" [UAS_PORT]="5090" [RTP_START]="16384" [RTP_END]="32768"
    [STATE_DIR]="/etc/flux-loadtest/vmlab" [LOADTEST_CONF_DIR]="/etc/flux-loadtest"
    [ZABBIX_SERVER]="" [ZABBIX_PORT]="10051" [ZABBIX_HOST_PREFIX]="lab-" [ZABBIX_API_URL]=""
    [ZABBIX_API_TOKEN_FILE]="" [ZABBIX_TLS_INSECURE]="0"
)
declare -A PUB=() INT=() NAME=()

load_config() {
    local line key val n=0
    [[ -r ${CONF_FILE} ]] || die "configuracao ausente: ${CONF_FILE} (rode: $0 init)"
    while IFS= read -r line || [[ -n ${line} ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ ${line} =~ ^[[:space:]]*(#|$) ]] && continue
        [[ ${line} =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "${CONF_FILE}:${n}: linha invalida (use CHAVE=valor)"
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        [[ -n ${CFG[${key}]+x} ]] || die "${CONF_FILE}:${n}: chave desconhecida: ${key}"
        if [[ ${val} =~ ^\"(.*)\"$ || ${val} =~ ^\'(.*)\'$ ]]; then
            val=${BASH_REMATCH[1]}
        fi
        CFG[${key}]=${val}
    done < "${CONF_FILE}"
}

is_ip() { [[ ${1:-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; }
is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

validate_config() {
    local h k ip pub int
    for k in SSH_PORT DB_VIP_PREFIX VRRP_ROUTER_ID SIP_DEVICES DIDS UAS_PORT RTP_START RTP_END ZABBIX_PORT; do
        is_uint "${CFG[${k}]}" || die "${k} deve ser inteiro: '${CFG[${k}]}'"
    done
    [[ ${CFG[SSH_ADMIN_USER]} =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SSH_ADMIN_USER invalido"
    is_ip "${CFG[GEN_IP]}" || die "GEN_IP invalido: '${CFG[GEN_IP]}'"
    is_ip "${CFG[DB_VIP]}" || die "DB_VIP invalido: '${CFG[DB_VIP]}'"
    ((CFG[VRRP_ROUTER_ID] >= 1 && CFG[VRRP_ROUTER_ID] <= 255)) || die "VRRP_ROUTER_ID fora de 1-255"
    ((CFG[RTP_START] >= 1024 && CFG[RTP_START] < CFG[RTP_END] && CFG[RTP_END] <= 65535)) || die "faixa RTP_START/RTP_END invalida"
    ((CFG[SIP_DEVICES] >= 1 && CFG[SIP_DEVICES] <= 900)) || die "SIP_DEVICES fora de 1-900"
    [[ ${CFG[NET_PATTERN]} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){0,3}\.%$ ]] || die "NET_PATTERN invalido (ex.: 10.10.%): '${CFG[NET_PATTERN]}'"
    [[ ${CFG[SET_HOSTNAME]} == [01] && ${CFG[ZABBIX_TLS_INSECURE]} == [01] ]] || die "SET_HOSTNAME e ZABBIX_TLS_INSECURE: 0 ou 1"
    for k in STATE_DIR LOADTEST_CONF_DIR FLUX_SRC_DIR; do
        [[ ${CFG[${k}]} == /* ]] || die "${k} deve ser caminho absoluto"
    done
    [[ -z ${CFG[FLUX_SCRIPTS_DIR]} || ${CFG[FLUX_SCRIPTS_DIR]} == /* ]] || die "FLUX_SCRIPTS_DIR deve ser caminho absoluto"
    [[ ${CFG[FLUX_GIT_REF]} =~ ^[A-Za-z0-9._/-]+$ ]] || die "FLUX_GIT_REF invalido"
    # shellcheck disable=SC2153  # HOSTS vem do chamador
    for h in "${HOSTS[@]}"; do
        read -r pub int _ <<< "${CFG[HOST_${h^^}]}"
        int=${int:-${pub}}
        is_ip "${pub}" && is_ip "${int}" || die "HOST_${h^^} invalido (use \"IP_PUBLICO IP_INTERNO\"): '${CFG[HOST_${h^^}]}'"
        [[ ${CFG[NAME_${h^^}]} =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "NAME_${h^^} invalido"
        PUB[${h}]=${pub}
        INT[${h}]=${int}
        NAME[${h}]=${CFG[NAME_${h^^}]}
    done
    for ip in "${PUB[@]}" "${INT[@]}"; do
        [[ ${ip} != "${CFG[DB_VIP]}" ]] || die "DB_VIP ${CFG[DB_VIP]} coincide com o IP de uma VM"
    done
}

# --------------------------------------------------------------- estado local (senhas, chave)
SECRETS=""
SSH_KEY="" KNOWN=""

state_paths() {
    SECRETS="${CFG[STATE_DIR]}/secrets.env"
    # shellcheck disable=SC2034  # usados pelo vmlab.sh (chave e known_hosts do orquestrador)
    SSH_KEY="${CFG[STATE_DIR]}/id_vmlab"
    # shellcheck disable=SC2034
    KNOWN="${CFG[STATE_DIR]}/known_hosts"
}

rand_alnum() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

secret() {
    local v
    v=$(awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${SECRETS}" 2>/dev/null)
    [[ -n ${v} ]] || die "$1 ausente em ${SECRETS} (rode: $0 init)"
    printf '%s' "${v}"
}

ensure_secrets() {
    local k
    install -d -m 0700 "${CFG[STATE_DIR]}"
    [[ -f ${SECRETS} ]] || (umask 077 && printf '# gerado pelo vmlab.sh: senhas do laboratorio em VMs (nao versionar)\n' > "${SECRETS}")
    for k in LOADTEST_PASSWORD MONITOR_PASSWORD BENCH_PASSWORD WEB_DB_PASSWORD FS_CLI_PASSWORD FLUX_DB_PASSWORD; do
        grep -q "^${k}=" "${SECRETS}" || printf '%s=%s\n' "${k}" "$(rand_alnum)" >> "${SECRETS}"
    done
    chmod 0600 "${SECRETS}"
}

# --------------------------------------------------------------- papeis
# role.env da VM: valores com printf %q (lidos com "." pelos papeis)
role_env() {
    local h=$1 hosts="" x
    kv() { printf '%s=%q\n' "$1" "$2"; }
    for x in "${HOSTS[@]}"; do
        hosts+="${INT[${x}]} ${NAME[${x}]};"
    done
    hosts+="${CFG[GEN_IP]} vm-teste"
    kv LAB_HOSTNAME "${NAME[${h}]}"
    kv LAB_SET_HOSTNAME "${CFG[SET_HOSTNAME]}"
    kv LAB_HOSTS "${hosts}"
    kv LAB_LOADTEST_PASSWORD "$(secret LOADTEST_PASSWORD)"
    case "${h}" in
        db1|db2)
            local node=1 peer=db2 prio=150
            [[ ${h} == db2 ]] && { node=2; peer=db1; prio=100; }
            kv LAB_DB_NODE "${node}"
            kv LAB_DB_ADDR "${INT[${h}]}"
            kv LAB_DB_PEER "${INT[${peer}]}"
            kv LAB_CLUSTER_ADDR "${INT[db1]},${INT[db2]}"
            kv LAB_DB_VIP "${CFG[DB_VIP]}"
            kv LAB_DB_VIP_PREFIX "${CFG[DB_VIP_PREFIX]}"
            kv LAB_VRRP_ROUTER_ID "${CFG[VRRP_ROUTER_ID]}"
            kv LAB_VRRP_PRIORITY "${prio}"
            kv LAB_NET_PATTERN "${CFG[NET_PATTERN]}"
            kv LAB_MONITOR_PASSWORD "$(secret MONITOR_PASSWORD)"
            kv LAB_BENCH_PASSWORD "$(secret BENCH_PASSWORD)"
            kv LAB_WEB_DB_PASSWORD "$(secret WEB_DB_PASSWORD)"
            ;;
        web)
            kv LAB_DB_VIP "${CFG[DB_VIP]}"
            kv LAB_WEB_DB_PASSWORD "$(secret WEB_DB_PASSWORD)"
            ;;
        sbc1|sbc2)
            kv LAB_SIP_ROLES "$([[ ${h} == sbc1 ]] && printf 'fs opensips' || printf 'fs')"
            kv LAB_PUB_IP "${PUB[${h}]}"
            kv LAB_INT_IP "${INT[${h}]}"
            kv LAB_DB_VIP "${CFG[DB_VIP]}"
            kv LAB_GEN_IP "${CFG[GEN_IP]}"
            kv LAB_FS_PUB_IPS "${PUB[sbc1]} ${PUB[sbc2]}"
            kv LAB_FS_INT_IPS "${INT[sbc1]} ${INT[sbc2]}"
            kv LAB_FLUX_DB_PASSWORD "$(secret FLUX_DB_PASSWORD)"
            kv LAB_FS_CLI_PASSWORD "$(secret FS_CLI_PASSWORD)"
            kv LAB_RTP_START "${CFG[RTP_START]}"
            kv LAB_RTP_END "${CFG[RTP_END]}"
            kv LAB_DEV_PROFILE lab-dev
            ;;
    esac
}

# Envia papeis e modelos (/opt/flux-lab) e o role.env (0600) para a VM
# --------------------------------------------------------------- Flux
cmd_flux_src() {
    local dir=${CFG[FLUX_SRC_DIR]}
    [[ -n ${CFG[FLUX_GIT_URL]} ]] || die "FLUX_GIT_URL vazio no ${CONF_FILE}"
    command -v git >/dev/null 2>&1 || die "git ausente (rode: $0 gen)"
    if [[ -d ${dir}/.git ]]; then
        log "atualizando ${dir} (${CFG[FLUX_GIT_REF]})"
        git -C "${dir}" fetch --prune origin || die "git fetch falhou em ${dir}"
        git -C "${dir}" checkout -q "${CFG[FLUX_GIT_REF]}" || die "ref ${CFG[FLUX_GIT_REF]} inexistente"
        if git -C "${dir}" symbolic-ref -q HEAD >/dev/null; then
            git -C "${dir}" merge -q --ff-only "origin/${CFG[FLUX_GIT_REF]}" || die "${dir} divergiu de origin/${CFG[FLUX_GIT_REF]}; resolva manualmente"
        fi
    elif [[ -e ${dir} ]]; then
        die "${dir} existe e nao e um clone git"
    else
        log "clonando ${CFG[FLUX_GIT_URL]} (${CFG[FLUX_GIT_REF]}) em ${dir}"
        git clone -q --branch "${CFG[FLUX_GIT_REF]}" "${CFG[FLUX_GIT_URL]}" "${dir}" \
            || die "git clone falhou (repositorio privado: chave de deploy ou credencial do git)"
    fi
    [[ -f ${dir}/database/flux-6.4.sql && -d ${dir}/freeswitch/scripts/flux ]] \
        || die "${dir} nao parece o repositorio sbc (database/, freeswitch/scripts/flux)"
    log "Flux em ${dir}: $(git -C "${dir}" log -1 --format='%h %s' | cut -c1-80)"
}


fluxdb_vars() {
    # shellcheck source=lab/lib/flux-db.sh
    source "${LAB_DIR}/lib/flux-db.sh"
    FLUXDB_OUT_DIR=${CFG[STATE_DIR]}
    FLUXDB_NET_PATTERN=${CFG[NET_PATTERN]}
    FLUXDB_OPENSIPS_DOMAIN=${PUB[sbc1]}
    FLUXDB_UAS_ADDR="${CFG[GEN_IP]}:${CFG[UAS_PORT]}"
    FLUXDB_DEV_PROFILE=lab-dev
    # shellcheck disable=SC2016
    FLUXDB_DEV_EXT_RTP_IP='$${local_ip_v4}'
}

cmd_flux() {
    local src=${CFG[FLUX_SRC_DIR]} n devices errlog
    flux_require_db
    fluxdb_vars
    errlog="${CFG[STATE_DIR]}/logs/flux-schema.log"
    install -d -m 0700 "${CFG[STATE_DIR]}/logs"
    n=$(root_sql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'flux' AND table_name = 'sip_profiles'" </dev/null) \
        || die "banco indisponivel no ${NAME[db1]} (rode: $0 db)"
    if [[ ${n} == 0 ]]; then
        log "carregando o schema do Flux de ${src}/database (erros em ${errlog})"
        fluxdb_load_schema "${src}" "${errlog}" root_sql
        log "schema carregado: $(root_sql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'flux'" </dev/null) tabelas; $(grep -c '^ERROR' "${errlog}" || true) erros ignorados (-f, como no instalador)"
    else
        log "schema do Flux ja existe no cluster"
    fi
    devices=$(fluxdb_devices_file "${CFG[SIP_DEVICES]}")
    log "gravando fluxuser, ${CFG[SIP_DEVICES]} ramais, ${CFG[DIDS]} DIDs DIRECT-IP para ${FLUXDB_UAS_ADDR} e perfis SIP"
    fluxdb_seed_sql "${devices}" "${CFG[DIDS]}" "$(secret FLUX_DB_PASSWORD)" | root_sql \
        || die "falha ao gravar os dados do laboratorio"
    log "banco do Flux pronto"
}

# --------------------------------------------------------------- flux-loadtest no servidor de testes
cmd_conf() {
    local dir=${CFG[LOADTEST_CONF_DIR]} conf
    conf="${dir}/loadtest.conf"
    install -d -m 0750 "${dir}" /var/lib/flux-loadtest/results
    (
        umask 077
        secret LOADTEST_PASSWORD > "${dir}/loadtest.pass"
        secret FS_CLI_PASSWORD > "${dir}/fs_cli.pass"
        secret BENCH_PASSWORD > "${dir}/mysql_bench.pass"
        printf '\n' | tee -a "${dir}/loadtest.pass" "${dir}/fs_cli.pass" "${dir}/mysql_bench.pass" >/dev/null
    )
    {
        printf '# DIDs DIRECT-IP do laboratorio em VMs (gerados pelo vmlab.sh)\n'
        awk -v n="${CFG[DIDS]}" 'BEGIN { for (i = 0; i < n; i++) printf "55519%08d\n", i }'
    } > "${dir}/dids.txt"
    cat > "${conf}" <<CONF
# flux-loadtest - laboratorio STFC em VMs Debian 12 (gerado pelo vmlab.sh)
SSH_USER=loadtest
SSH_KEY=${dir}/id_ed25519
SSH_PORT=22
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes"
SSH_KNOWN_HOSTS=${dir}/known_hosts

OPENSIPS_HOST=${PUB[sbc1]}
FS_HOSTS="${PUB[sbc1]} ${PUB[sbc2]}"
DB_HOSTS="${PUB[db1]} ${PUB[db2]}"
WEB_HOST=${PUB[web]}

SIP_TARGET=${PUB[sbc1]}:5060
SIP_LOCAL_IP=${CFG[GEN_IP]}
DID_FILE=${dir}/dids.txt
CALLER_ID=551130009999
UAS_PORT=${CFG[UAS_PORT]}

FS_CLI_CMD="sudo -n fs_cli -x"
FS_CLI_PASSWORD_FILE=${dir}/fs_cli.pass
OPENSIPS_MI_CMD="sudo -n opensips-cli -x mi"
MYSQL_CLI_CMD="mysql --defaults-extra-file=/etc/mysql/flux-loadtest.cnf"
DB_VIP=${CFG[DB_VIP]}

NGINX_STATUS_URL=http://127.0.0.1/nginx_status
FPM_STATUS_URL=http://127.0.0.1/fpm-status?json
WEB_BASE_URL=https://${PUB[web]}

MYSQL_BENCH_HOST=${CFG[DB_VIP]}
MYSQL_BENCH_USER=flux_bench
MYSQL_BENCH_PASSWORD_FILE=${dir}/mysql_bench.pass
MYSQL_BENCH_TABLES=2
MYSQL_BENCH_TABLE_SIZE=20000
MYSQL_BENCH_THREADS=4

GUARD_MIN_WSREP_CLUSTER_SIZE=2
RESULTS_DIR=/var/lib/flux-loadtest/results
CONF
    if [[ -n ${CFG[ZABBIX_SERVER]} || -n ${CFG[ZABBIX_API_URL]} ]]; then
        cat >> "${conf}" <<CONF

# Zabbix existente
ZABBIX_SERVER=${CFG[ZABBIX_SERVER]}
ZABBIX_PORT=${CFG[ZABBIX_PORT]}
ZABBIX_HOST_PREFIX=${CFG[ZABBIX_HOST_PREFIX]}
ZABBIX_LIVE=1
ZABBIX_API_URL=${CFG[ZABBIX_API_URL]}
ZABBIX_API_TOKEN_FILE=${CFG[ZABBIX_API_TOKEN_FILE]}
ZABBIX_TLS_INSECURE=${CFG[ZABBIX_TLS_INSECURE]}
CONF
    fi
    chmod 0640 "${conf}"
    log "configuracao do flux-loadtest: ${conf} (${CFG[DIDS]} DIDs em ${dir}/dids.txt)"
}

flt() { "${REPO_DIR}/flux-loadtest.sh" "$@" -c "${CFG[LOADTEST_CONF_DIR]}/loadtest.conf"; }

cmd_keys() {
    local dir=${CFG[LOADTEST_CONF_DIR]}
    [[ -f ${dir}/loadtest.conf ]] || die "configuracao ausente (rode: $0 conf)"
    command -v expect >/dev/null 2>&1 || die "expect ausente (rode: $0 gen)"
    FLT_BIN="${REPO_DIR}/flux-loadtest.sh" FLT_CONF="${dir}/loadtest.conf" FLT_PASS="${dir}/loadtest.pass" \
        expect -f "${LAB_DIR}/images/gen/keys-setup.exp"
}

cmd_zabbix() {
    if [[ -z ${CFG[ZABBIX_API_URL]} ]]; then
        log "ZABBIX_API_URL vazio: sem Zabbix"
        return 0
    fi
    [[ -r ${CFG[ZABBIX_API_TOKEN_FILE]} ]] || die "ZABBIX_API_TOKEN_FILE ilegivel: '${CFG[ZABBIX_API_TOKEN_FILE]}'"
    flt zabbix setup --import-template
}

cmd_smoke() {
    flt check
    flt smoke --did 5551900000000
}

