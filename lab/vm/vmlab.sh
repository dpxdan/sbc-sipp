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
# shellcheck source=lab/lib/inventory.sh
source "${LAB_DIR}/lib/inventory.sh"

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
        log "criado ${CONF_FILE}: ajuste IPs, VIP, NET_PATTERN e FLUX_GIT_URL e rode '$0 init -c ${CONF_FILE}' de novo"
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
    log "senhas em ${SECRETS} (0600). Proximo passo: $0 bootstrap -c ${CONF_FILE}"
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

# cmd_flux (lib/inventory.sh): requer o no 1 acessivel por SSH
flux_require_db() { require_ssh db1; }

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
