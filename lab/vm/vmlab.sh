#!/usr/bin/env bash
#
# vmlab.sh - laboratorio STFC do flux-loadtest em VMs Debian 12, sem Docker (WEB-1437)
#
# Roda no servidor de testes (VM originadora), como root. Configura por SSH as outras 5 VMs
# com os mesmos papeis do STFC e do lab Docker (lab/lab.sh):
#   sbc-stfc-1   OpenSIPS 3.6 + FreeSWITCH 1.11.3 (stack Flux)
#   sbc-stfc-02  FreeSWITCH 1.11.3
#   banco-*      Percona XtraDB Cluster 8.4.10 (2 nos) + keepalived (VIP)
#   interfaceweb nginx + PHP-FPM 7.3
# O servidor de testes roda o flux-loadtest (originador e atendedor). Zabbix: um servidor
# existente (ZABBIX_* no vmlab.conf).
#
# Uso: ./vmlab.sh <acao> [-c vmlab.conf] [-y]   (acoes em "./vmlab.sh help")

set -Eeuo pipefail
export LC_ALL=C

VMLAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VMLAB_DIR
readonly LAB_DIR="${VMLAB_DIR%/vm}"
readonly REPO_DIR="${LAB_DIR%/lab}"
readonly HOSTS=(sbc1 sbc2 db1 db2 web)

log()  { printf '[%(%H:%M:%S)T] [vmlab] %s\n' -1 "$*"; }
warn() { printf '[%(%H:%M:%S)T] [vmlab] AVISO: %s\n' -1 "$*" >&2; }
die()  { printf '[%(%H:%M:%S)T] [vmlab] ERRO: %s\n' -1 "$*" >&2; exit 1; }

trap 'printf "[vmlab] falha na linha %s: %s\n" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

usage() {
    cat <<EOF
Uso: $0 <acao> [-c ARQUIVO] [-y]

Preparacao (uma vez):
  init        cria o vmlab.conf a partir do exemplo (se faltar), as senhas do laboratorio
              e a chave SSH do orquestrador em STATE_DIR
  bootstrap   confere Debian 12 nas 5 VMs, grava as chaves de host, instala a chave do
              orquestrador no SSH_ADMIN_USER (pede a senha) e libera sudo sem senha para ele

Instalacao (idempotente; "up" faz tudo na ordem):
  up          gen, flux-src, common, db, flux, web, sbc, conf, keys, zabbix, smoke
  gen         pacotes e limites do servidor de testes (local)
  flux-src    clona ou atualiza o fork do Flux (FLUX_GIT_URL/FLUX_GIT_REF) em FLUX_SRC_DIR
  common      pacotes base, /etc/hosts, relogio e usuario loadtest nas 5 VMs
  db          PXC no no 1 (bootstrap), no 2 (SST), keepalived; no 1 volta a membro comum
  flux        schema do Flux (primeira vez) e dados: fluxuser, ramais, perfis SIP, DIDs
              DIRECT-IP para GEN_IP:UAS_PORT
  web         nginx + PHP-FPM 7.3 na interfaceweb
  sbc         FreeSWITCH no sbc-stfc-02 e FreeSWITCH + OpenSIPS no sbc-stfc-1
  conf        gera LOADTEST_CONF_DIR/loadtest.conf, dids.txt e os arquivos de senha
  keys        flux-loadtest.sh keys setup (responde a senha do usuario loadtest)
  zabbix      importa os templates e cria os hosts no Zabbix existente (ZABBIX_API_URL)
  smoke       flux-loadtest.sh check e uma chamada para um DID DIRECT-IP

Operacao:
  status      servicos de cada VM, estado do cluster e no do VIP
  ssh HOST    shell na VM (sbc1, sbc2, db1, db2, web) com a chave do orquestrador

Opcoes:
  -c ARQUIVO  configuracao (padrao: ${VMLAB_DIR}/vmlab.conf)
  -y          nao pede confirmacao no bootstrap (aceita as chaves de host exibidas)
EOF
}

# --------------------------------------------------------------- configuracao
CONF_FILE="${VMLAB_DIR}/vmlab.conf"
ASSUME_YES=0
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
    SSH_KEY="${CFG[STATE_DIR]}/id_vmlab"
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

# --------------------------------------------------------------- SSH
ssh_opts() {
    SSH_OPTS=(-i "${SSH_KEY}" -p "${CFG[SSH_PORT]}" -o BatchMode=yes -o ConnectTimeout=10
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o IdentitiesOnly=yes
        -o UserKnownHostsFile="${KNOWN}" -o StrictHostKeyChecking=yes -o LogLevel=ERROR)
}

# remote HOST COMANDO: comando (texto) na VM pelo IP publico, stdin repassado
remote() {
    local h=$1
    shift
    ssh "${SSH_OPTS[@]}" -T "${CFG[SSH_ADMIN_USER]}@${PUB[${h}]}" "$@"
}

remote_ok() {
    remote "$1" true </dev/null >/dev/null 2>&1
}

require_ssh() {
    local h
    [[ -r ${SSH_KEY} && -s ${KNOWN} ]] || die "chave do orquestrador ausente; rode: $0 init e $0 bootstrap"
    for h in "$@"; do
        remote "${h}" 'sudo -n true' </dev/null >/dev/null 2>&1 \
            || die "${h} (${PUB[${h}]}): SSH ou sudo sem senha indisponivel; rode: $0 bootstrap"
    done
}

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
push_role_files() {
    local h=$1
    tar -C "${LAB_DIR}" -cf - vm/roles images/db images/web images/sbc-real \
        | remote "${h}" "sudo sh -c 'rm -rf /opt/flux-lab.new && mkdir -p /opt/flux-lab.new && tar -C /opt/flux-lab.new --no-same-owner -xf - && rm -rf /opt/flux-lab && mv /opt/flux-lab.new /opt/flux-lab'" \
        || die "${h}: falha ao enviar os papeis"
    role_env "${h}" | remote "${h}" "sudo sh -c 'umask 077; mkdir -p /etc/flux-lab && cat > /etc/flux-lab/role.env'" \
        || die "${h}: falha ao gravar o role.env"
}

# run_role HOST PAPEL [ARG] [ARQUIVO_STDIN]: saida no terminal e em STATE_DIR/logs
run_role() {
    local h=$1 role=$2 arg=${3:-} in=${4:-/dev/null} logf
    install -d -m 0700 "${CFG[STATE_DIR]}/logs"
    logf="${CFG[STATE_DIR]}/logs/${h}-${role}.log"
    log "${h} (${NAME[${h}]}, ${PUB[${h}]}): papel ${role}${arg:+ ${arg}}"
    # pipefail: a falha do papel (ssh) derruba o pipeline mesmo com sed/tee ok
    if ! remote "${h}" "sudo bash /opt/flux-lab/vm/roles/${role}.sh ${arg}" < "${in}" 2>&1 \
            | sed "s/^/  [${h}] /" | tee "${logf}"; then
        die "${h}: papel ${role} falhou (log: ${logf})"
    fi
}

# --------------------------------------------------------------- acoes
cmd_init() {
    if [[ ! -f ${CONF_FILE} ]]; then
        install -m 0600 "${VMLAB_DIR}/vmlab.conf.example" "${CONF_FILE}"
        log "criado ${CONF_FILE}: ajuste IPs, VIP, NET_PATTERN e FLUX_GIT_URL e rode '$0 init' de novo"
        return 0
    fi
    load_config
    validate_config
    state_paths
    ensure_secrets
    if [[ ! -f ${SSH_KEY} ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "vmlab@$(uname -n)" -f "${SSH_KEY}"
        log "chave do orquestrador: ${SSH_KEY}"
    fi
    log "senhas em ${SECRETS} (0600). Proximo passo: $0 bootstrap"
}

cmd_bootstrap() {
    local h ip ans keys
    for h in "${HOSTS[@]}"; do
        ip=${PUB[${h}]}
        keys=$(ssh-keyscan -p "${CFG[SSH_PORT]}" -T 5 "${ip}" 2>/dev/null) || true
        [[ -n ${keys} ]] || die "${h} (${ip}): ssh-keyscan sem resposta"
        printf '\n%s (%s, %s):\n' "${h}" "${NAME[${h}]}" "${ip}"
        ssh-keygen -lf - <<< "${keys}" | sed 's/^/  /'
        if ((ASSUME_YES == 0)); then
            read -r -p "  Confere com o console da VM? [s/N] " ans
            [[ ${ans} == [sS] ]] || die "chave de host de ${h} nao confirmada"
        fi
        ssh-keygen -R "${ip}" -f "${KNOWN}" >/dev/null 2>&1 || true
        printf '%s\n' "${keys}" >> "${KNOWN}"
        chmod 0600 "${KNOWN}"
        if ! remote_ok "${h}"; then
            log "${h}: instalando a chave do orquestrador em ${CFG[SSH_ADMIN_USER]}@${ip} (senha do usuario)"
            ssh-copy-id -i "${SSH_KEY}.pub" -p "${CFG[SSH_PORT]}" -o UserKnownHostsFile="${KNOWN}" \
                -o StrictHostKeyChecking=yes "${CFG[SSH_ADMIN_USER]}@${ip}" >/dev/null \
                || die "${h}: ssh-copy-id falhou"
        fi
        remote "${h}" '. /etc/os-release && [ "${ID}" = debian ] && [ "${VERSION_ID}" = 12 ]' </dev/null \
            || die "${h}: nao e Debian 12"
        if ! remote "${h}" 'sudo -n true' </dev/null >/dev/null 2>&1; then
            log "${h}: liberando sudo sem senha para ${CFG[SSH_ADMIN_USER]} (senha do sudo)"
            ssh "${SSH_OPTS[@]/BatchMode=yes/BatchMode=no}" -t "${CFG[SSH_ADMIN_USER]}@${ip}" \
                "sudo sh -c 'printf \"%s ALL=(ALL) NOPASSWD:ALL\\n\" ${CFG[SSH_ADMIN_USER]} > /etc/sudoers.d/90-flux-lab-admin && chmod 0440 /etc/sudoers.d/90-flux-lab-admin && visudo -cf /etc/sudoers.d/90-flux-lab-admin'" \
                || die "${h}: nao foi possivel liberar o sudo"
        fi
        log "${h}: SSH por chave e sudo ok"
    done
    log "bootstrap concluido. Proximo passo: $0 up"
}

cmd_gen() {
    bash "${VMLAB_DIR}/roles/gen.sh"
}

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

cmd_common() {
    local h
    require_ssh "${HOSTS[@]}"
    for h in "${HOSTS[@]}"; do
        push_role_files "${h}"
        run_role "${h}" common
    done
}

# Estado do cluster visto pelo no 2: tamanho e estado local
cluster_state() {
    remote db2 "sudo mysql -N -B -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_local_state_comment')\"" </dev/null 2>/dev/null \
        | awk '{ v[$1] = $2 } END { print v["wsrep_cluster_size"], v["wsrep_local_state_comment"] }'
}

cmd_db() {
    local i size state
    require_ssh db1 db2
    push_role_files db1
    push_role_files db2
    run_role db1 db install
    run_role db2 db install
    for ((i = 0; i < 120; i++)); do
        read -r size state < <(cluster_state || true)
        [[ ${size:-0} == 2 && ${state:-} == Synced ]] && break
        sleep 5
    done
    [[ ${size:-0} == 2 && ${state:-} == Synced ]] || die "cluster nao formou (tamanho ${size:-?}, no 2 ${state:-?})"
    log "cluster com 2 nos, ${NAME[db2]} Synced"
    run_role db1 db normalize
}

# SQL como root no no 1 (auth_socket): argumentos do cliente mysql, SQL pelo stdin
root_sql() {
    remote db1 "sudo mysql --default-character-set=utf8 $(printf '%q ' "$@")"
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
    require_ssh db1
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

cmd_web() {
    require_ssh web
    push_role_files web
    run_role web web
}

# Envia o clone do Flux (so o que o SBC usa) e, se houver, os scripts Lua de producao
push_flux_src() {
    local h=$1 src=${CFG[FLUX_SRC_DIR]} scripts=${CFG[FLUX_SCRIPTS_DIR]}
    [[ -d ${src}/freeswitch && -d ${src}/config ]] || die "${src} incompleto (rode: $0 flux-src)"
    tar -C "${src}" -cf - freeswitch config web_interface/nginx \
        | remote "${h}" "sudo sh -c 'rm -rf /opt/flux-src.new && mkdir -p /opt/flux-src.new && tar -C /opt/flux-src.new --no-same-owner -xf - && rm -rf /opt/flux-src && mv /opt/flux-src.new /opt/flux-src'" \
        || die "${h}: falha ao enviar ${src}"
    if [[ -n ${scripts} ]]; then
        [[ -f ${scripts}/flux/flux.lua ]] || die "FLUX_SCRIPTS_DIR sem flux/flux.lua: ${scripts}"
        tar -C "${scripts}" -cf - . \
            | remote "${h}" "sudo sh -c 'rm -rf /opt/flux-scripts.new && mkdir -p /opt/flux-scripts.new && tar -C /opt/flux-scripts.new --no-same-owner -xf - && rm -rf /opt/flux-scripts && mv /opt/flux-scripts.new /opt/flux-scripts'" \
            || die "${h}: falha ao enviar ${scripts}"
    else
        remote "${h}" "sudo rm -rf /opt/flux-scripts" </dev/null
        warn "${h}: FLUX_SCRIPTS_DIR vazio; o dialplan usa os scripts Lua do clone"
    fi
}

cmd_sbc() {
    local h tok=${CFG[SIGNALWIRE_TOKEN_FILE]} in
    require_ssh sbc1 sbc2
    for h in sbc2 sbc1; do
        push_role_files "${h}"
        push_flux_src "${h}"
        in=/dev/null
        # o token so e necessario na primeira instalacao do FreeSWITCH
        if ! remote "${h}" 'dpkg -s freeswitch >/dev/null 2>&1' </dev/null; then
            [[ -r ${tok} ]] || die "token da SignalWire ilegivel: ${tok} (SIGNALWIRE_TOKEN_FILE)"
            [[ $(stat -c %a "${tok}") == 600 ]] || die "${tok} deve ter permissao 0600"
            in=${tok}
        fi
        run_role "${h}" sbc "" "${in}"
    done
}

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

cmd_status() {
    local h
    require_ssh
    for h in "${HOSTS[@]}"; do
        printf '\n== %s (%s, %s / %s)\n' "${h}" "${NAME[${h}]}" "${PUB[${h}]}" "${INT[${h}]}"
        if ! remote_ok "${h}"; then
            printf '  SSH indisponivel\n'
            continue
        fi
        case "${h}" in
            db1|db2)
                remote "${h}" "systemctl is-active mysql mysql@bootstrap keepalived | paste -sd ' ' -; sudo mysql -N -B -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment')\" | paste -sd ' ' -; ip -o -4 addr show | grep -q ' ${CFG[DB_VIP]}/' && echo 'VIP ${CFG[DB_VIP]}: neste no' || echo 'VIP ${CFG[DB_VIP]}: em outro no'" </dev/null 2>&1 | sed 's/^/  /' ;;
            web)
                remote "${h}" "systemctl is-active nginx php7.3-fpm | paste -sd ' ' -" </dev/null 2>&1 | sed 's/^/  /' ;;
            sbc1|sbc2)
                remote "${h}" "systemctl is-active freeswitch php7.3-fpm nginx $([[ ${h} == sbc1 ]] && echo opensips) | paste -sd ' ' -; sudo fs_cli -x 'sofia status' | awk '\$2 == \"profile\" { print \$1, \$3, \$4 }'" </dev/null 2>&1 | sed 's/^/  /' ;;
        esac
    done
}

cmd_ssh() {
    local h=${1:-}
    [[ -n ${h} && -n ${PUB[${h}]+x} ]] || die "uso: $0 ssh <sbc1|sbc2|db1|db2|web>"
    exec ssh "${SSH_OPTS[@]/BatchMode=yes/BatchMode=no}" -t "${CFG[SSH_ADMIN_USER]}@${PUB[${h}]}"
}

cmd_up() {
    cmd_gen
    cmd_flux_src
    cmd_common
    cmd_db
    cmd_flux
    cmd_web
    cmd_sbc
    cmd_conf
    cmd_keys
    cmd_zabbix
    cmd_smoke
    log "laboratorio pronto. Teste de carga: ${REPO_DIR}/flux-loadtest.sh run -c ${CFG[LOADTEST_CONF_DIR]}/loadtest.conf --confirm-prod ..."
}

main() {
    local action=${1:-help}
    (($# > 0)) && shift
    local -a rest=()
    while (($# > 0)); do
        case "$1" in
            -c) CONF_FILE=${2:-}; shift 2 ;;
            -y) ASSUME_YES=1; shift ;;
            *)  rest+=("$1"); shift ;;
        esac
    done
    case "${action}" in
        help|-h|--help) usage; return 0 ;;
        init) ((EUID == 0)) || die "rode como root"; cmd_init; return 0 ;;
    esac
    ((EUID == 0)) || die "rode como root (instala pacotes e grava em /etc/flux-loadtest)"
    load_config
    validate_config
    state_paths
    ssh_opts
    case "${action}" in
        bootstrap) [[ -r ${SSH_KEY} ]] || die "rode antes: $0 init"; cmd_bootstrap ;;
        up)        cmd_up ;;
        gen)       cmd_gen ;;
        flux-src)  cmd_flux_src ;;
        common)    cmd_common ;;
        db)        cmd_db ;;
        flux)      cmd_flux ;;
        web)       cmd_web ;;
        sbc)       cmd_sbc ;;
        conf)      cmd_conf ;;
        keys)      cmd_keys ;;
        zabbix)    cmd_zabbix ;;
        smoke)     cmd_smoke ;;
        status)    cmd_status ;;
        ssh)       cmd_ssh "${rest[@]+"${rest[@]}"}" ;;
        *)         usage >&2; die "acao invalida: ${action}" ;;
    esac
}

main "$@"
