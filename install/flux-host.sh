#!/usr/bin/env bash
#
# flux-host.sh - instalador local por papel do flux-loadtest em Debian 12 (WEB-1437)
#
# Roda como root NO PROPRIO SERVIDOR (sem orquestrador por SSH). Papeis:
#   freeswitch   FreeSWITCH 1.11.3 com a stack Flux (sbc-stfc-1, sbc-stfc-02)
#   opensips     OpenSIPS 3.6 (sbc-stfc-1)
#   mysql        Percona XtraDB Cluster 8.4.10 + keepalived (banco-master, banco-slave)
#   web          nginx + PHP-FPM 7.3 (interfaceweb)
#   gen          servidor de testes: SIPp, wrk, sysbench e o loadtest.conf
#   zabbix-agent servidor de testes (prepare): zabbix-agentd e flux-loadtest-zbx para iniciar
#                perfis pela interface do Zabbix
#
# Modos:
#   lab      instalacao completa de laboratorio, com os papeis de lab/vm/roles (os mesmos
#            do vmlab.sh): pacotes, configuracao e servicos systemd
#   prepare  servidores existentes (STFC): so os pre-requisitos do flux-loadtest; nunca
#            instala, atualiza ou reinicia FreeSWITCH, OpenSIPS ou MySQL (install/prepare.sh)
#   check    somente leitura
#
# Uso: ./flux-host.sh <acao> [papel...] [opcoes]   (acoes em "./flux-host.sh help")

set -Eeuo pipefail
export LC_ALL=C

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR
readonly REPO_DIR="${INSTALL_DIR%/install}"
readonly LAB_DIR="${REPO_DIR}/lab"
readonly ROLES_DIR="${LAB_DIR}/vm/roles"
readonly HOSTS=(sbc1 sbc2 db1 db2 web)
readonly ROLE_ENV=/etc/flux-lab/role.env
readonly LOG_DIR=/var/log/flux-host

log()  { printf '[%(%H:%M:%S)T] [flux-host] %s\n' -1 "$*"; }
warn() { printf '[%(%H:%M:%S)T] [flux-host] AVISO: %s\n' -1 "$*" >&2; }
die()  { printf '[%(%H:%M:%S)T] [flux-host] ERRO: %s\n' -1 "$*" >&2; exit 1; }

trap 'printf "[flux-host] falha na linha %s: %s\n" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

usage() {
    cat <<EOF
Uso: $0 <acao> [papel...] [opcoes]

Papeis: freeswitch, opensips, mysql, web, gen, zabbix-agent (so prepare/check, no servidor de
testes). Varios no mesmo servidor: "freeswitch opensips"

Laboratorio (host.conf + secrets.env iguais em todos os servidores):
  init               no servidor de testes: cria o host.conf (se faltar) e, depois de
                     ajustado, as senhas do laboratorio (STATE_DIR/secrets.env)
  lab PAPEL...       instala o papel neste servidor (idempotente)
  mysql-schema       no no 1 do banco: schema do Flux e dados do laboratorio
  keys | smoke | zabbix
                     no servidor de testes: chaves SSH, check + uma chamada, Zabbix

  Ordem: db1 "lab mysql" -> db2 "lab mysql" -> db1 "lab mysql" (volta a membro comum)
         -> db1 "mysql-schema" -> web "lab web" -> sbc-stfc-02 "lab freeswitch"
         -> sbc-stfc-1 "lab freeswitch opensips" -> servidor de testes "lab gen", "keys", "smoke"

Servidores existentes (STFC), sem host.conf:
  prepare PAPEL...   pre-requisitos do flux-loadtest (usuario loadtest, sudoers, credencial de
                     coleta do MySQL, status do nginx/PHP-FPM); mostra o plano e pede confirmacao
  check PAPEL...     estado dos servicos e dos pre-requisitos (somente leitura)

Opcoes:
  -c ARQUIVO              host.conf (padrao: /etc/flux-lab/host.conf)
  --as ID                 este servidor no inventario: sbc1, sbc2, db1, db2, web ou gen
                          (padrao: detectado pelos IPs locais)
  --dry-run               prepare: so mostra o plano
  -y                      prepare: nao pede confirmacao
  --monitor-pass-file ARQ prepare mysql: senha do flux_monitor (arquivo 0600, alfanumerica)
  --create-db-user        prepare mysql: cria o flux_monitor (uma vez, em um no do cluster)
  --apply-status          prepare web: cria o status do nginx e do PHP-FPM em 127.0.0.1 e
                          recarrega os servicos (reload, sem derrubar conexoes)
  --zabbix-server IP      prepare zabbix-agent: Server= do agent (instala o agent se faltar)
EOF
}

# --------------------------------------------------------------- opcoes
CONF_FILE=/etc/flux-lab/host.conf
SELF=""
DRY_RUN=0
ASSUME_YES=0
MONITOR_PASS_FILE=""
CREATE_DB_USER=0
APPLY_STATUS=0
ZBX_SERVER=""
ROLES=()

# shellcheck source=lab/lib/inventory.sh
source "${LAB_DIR}/lib/inventory.sh"
# shellcheck source=install/prepare.sh
source "${INSTALL_DIR}/prepare.sh"

require_root() { ((EUID == 0)) || die "rode como root"; }

require_debian12() {
    local id="" ver=""
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && { id=$(. /etc/os-release && printf '%s' "${ID}"); ver=$(. /etc/os-release && printf '%s' "${VERSION_ID}"); }
    [[ ${id} == debian && ${ver} == 12 ]] || die "Debian 12 necessario (encontrado: ${id:-?} ${ver:-?})"
}

valid_roles() {
    local r
    ((${#ROLES[@]} > 0)) || die "informe ao menos um papel (freeswitch, opensips, mysql, web, gen)"
    for r in "${ROLES[@]}"; do
        case "${r}" in
            freeswitch|opensips|mysql|web|gen|zabbix-agent) ;;
            *) die "papel invalido: ${r} (freeswitch, opensips, mysql, web, gen, zabbix-agent)" ;;
        esac
    done
}

has_req() {
    local r
    for r in "${ROLES[@]}"; do
        [[ ${r} == "$1" ]] && return 0
    done
    return 1
}

# --------------------------------------------------------------- inventario (modo lab)
load_inventory() {
    [[ -r ${CONF_FILE} ]] || die "configuracao ausente: ${CONF_FILE} (copie o host.conf do servidor de testes ou use -c)"
    load_config
    validate_config
    state_paths
}

# Id deste servidor: --as ou o IP local que aparece no inventario
detect_self() {
    local h ip found="" n=0
    local -a ips
    if [[ -n ${SELF} ]]; then
        [[ ${SELF} == gen || -n ${PUB[${SELF}]+x} ]] || die "--as invalido: ${SELF} (sbc1, sbc2, db1, db2, web, gen)"
        return 0
    fi
    # instalacao minima pode nao ter o iproute2 (o papel common instala): hostname -I
    if command -v ip >/dev/null 2>&1; then
        mapfile -t ips < <(ip -o -4 addr show | awk '{ split($4, a, "/"); print a[1] }')
    else
        read -r -a ips <<< "$(hostname -I)"
    fi
    for ip in "${ips[@]}"; do
        if [[ ${ip} == "${CFG[GEN_IP]}" && ${found} != gen ]]; then
            found=gen
            n=$((n + 1))
        fi
        for h in "${HOSTS[@]}"; do
            if [[ (${ip} == "${PUB[${h}]}" || ${ip} == "${INT[${h}]}") && ${found} != "${h}" ]]; then
                found=${h}
                n=$((n + 1))
            fi
        done
    done
    ((n == 1)) || die "nao foi possivel identificar este servidor pelos IPs locais (${ips[*]}); use --as"
    SELF=${found}
}

host_label() {
    if [[ ${SELF} == gen ]]; then
        printf 'servidor de testes (%s)' "${CFG[GEN_IP]}"
    else
        printf '%s (%s, %s)' "${SELF}" "${NAME[${SELF}]}" "${PUB[${SELF}]}"
    fi
}

# Papel pedido x servidor do inventario
check_role_host() {
    local r ok
    for r in "${ROLES[@]}"; do
        case "${r}" in
            freeswitch|opensips) [[ ${SELF} == sbc1 || ${SELF} == sbc2 ]] && ok=1 || ok=0 ;;
            mysql)               [[ ${SELF} == db1 || ${SELF} == db2 ]] && ok=1 || ok=0 ;;
            web)                 [[ ${SELF} == web ]] && ok=1 || ok=0 ;;
            gen)                 [[ ${SELF} == gen ]] && ok=1 || ok=0 ;;
            zabbix-agent)        die "papel zabbix-agent: use '$0 prepare zabbix-agent --zabbix-server IP' no servidor de testes" ;;
        esac
        ((ok)) || die "papel ${r} nao corresponde a ${SELF} no inventario (use --as se a deteccao errou)"
    done
}

# role.env deste servidor (0600): o mesmo do vmlab.sh, mais as linhas extras (sobrescrevem)
write_role_env() {
    install -d -m 0755 /etc/flux-lab
    (
        umask 077
        {
            role_env "${SELF}"
            if (($# > 0)); then printf '%s\n' "$@"; fi
        } > "${ROLE_ENV}.new"
    )
    mv -f "${ROLE_ENV}.new" "${ROLE_ENV}"
}

# run_role PAPEL [ARG] [ARQUIVO_STDIN]: saida no terminal e em LOG_DIR
run_role() {
    local role=$1 arg=${2:-} in=${3:-/dev/null} logf
    install -d -m 0700 "${LOG_DIR}"
    logf="${LOG_DIR}/${role}.log"
    log "$(host_label): papel ${role}${arg:+ ${arg}}"
    # shellcheck disable=SC2086  # arg vazio nao vira argumento
    if ! bash "${ROLES_DIR}/${role}.sh" ${arg} < "${in}" 2>&1 | tee "${logf}"; then
        die "papel ${role} falhou (log: ${logf})"
    fi
}

ensure_git() {
    command -v git >/dev/null 2>&1 && return 0
    log "instalando git (clone do repositorio sbc)"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates
}

# --------------------------------------------------------------- acoes do laboratorio
cmd_init_host() {
    if [[ ! -f ${CONF_FILE} ]]; then
        install -d -m 0755 "$(dirname "${CONF_FILE}")"
        install -m 0600 "${INSTALL_DIR}/host.conf.example" "${CONF_FILE}"
        log "criado ${CONF_FILE}: ajuste IPs, VIP, NET_PATTERN e FLUX_GIT_URL e rode '$0 init' de novo"
        return 0
    fi
    load_inventory
    ensure_secrets
    log "senhas em ${SECRETS} (0600)"
    log "copie para os 5 servidores, nos mesmos caminhos e com permissao 0600: ${CONF_FILE} e ${SECRETS}"
    log "depois, em cada servidor: $0 lab <papel>   (ordem em '$0 help')"
}

# No 1: depois do no 2 Synced, sai do mysql@bootstrap (db.sh normalize)
maybe_normalize() {
    local size
    [[ ${SELF} == db1 ]] || return 0
    size=$(mysql -N -B -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '{ print $2 }') || true
    if [[ ${size:-0} -ge 2 ]]; then
        run_role db normalize
    else
        log "cluster com ${size:-?} no(s): rode '$0 lab mysql' no ${NAME[db2]} e repita aqui para o no 1 voltar a membro comum"
    fi
}

lab_sip() {
    local sip_roles="" scripts tok in=/dev/null
    has_req freeswitch && sip_roles+="fs "
    has_req opensips && sip_roles+="opensips"
    if has_req freeswitch; then
        ensure_git
        cmd_flux_src
        scripts=${CFG[FLUX_SCRIPTS_DIR]:-${CFG[FLUX_SRC_DIR]}/freeswitch/scripts}
        [[ -f ${scripts}/flux/flux.lua ]] || die "scripts Lua sem flux/flux.lua: ${scripts} (FLUX_SCRIPTS_DIR)"
        # o token so e necessario na primeira instalacao do FreeSWITCH
        if ! dpkg -s freeswitch >/dev/null 2>&1; then
            tok=${CFG[SIGNALWIRE_TOKEN_FILE]}
            [[ -r ${tok} ]] || die "token da SignalWire ilegivel: ${tok} (SIGNALWIRE_TOKEN_FILE)"
            [[ $(stat -c %a "${tok}") == 600 ]] || die "${tok} deve ter permissao 0600"
            in=${tok}
        fi
    fi
    write_role_env "LAB_SIP_ROLES=${sip_roles% }" \
        "LAB_FLUX_SRC_DIR=$(printf '%q' "${CFG[FLUX_SRC_DIR]}")" \
        "LAB_FLUX_SCRIPTS_DIR=$(printf '%q' "${scripts:-/nonexistent}")"
    run_role sbc "" "${in}"
}

cmd_lab() {
    local r
    valid_roles
    require_debian12
    load_inventory
    [[ -s ${SECRETS} ]] || die "${SECRETS} ausente: copie do servidor de testes (gerado por '$0 init')"
    detect_self
    check_role_host
    log "$(host_label): papeis ${ROLES[*]}"
    if [[ ${SELF} != gen ]]; then
        write_role_env
        run_role common
    fi
    for r in "${ROLES[@]}"; do
        case "${r}" in
            mysql)
                run_role db install
                maybe_normalize
                ;;
            web) run_role web ;;
            gen)
                run_role gen
                cmd_conf
                ;;
        esac
    done
    if has_req freeswitch || has_req opensips; then
        lab_sip
    fi
    log "$(host_label): pronto"
}

# SQL como root no no 1 local (auth_socket), SQL pelo stdin (usado por cmd_flux)
root_sql() { mysql --default-character-set=utf8 "$@"; }

flux_require_db() {
    [[ ${SELF} == db1 ]] || die "mysql-schema roda no no 1 (${NAME[db1]}); este servidor e ${SELF}"
    mysqladmin ping >/dev/null 2>&1 || die "mysqld local sem resposta (rode antes: $0 lab mysql)"
}

cmd_mysql_schema() {
    require_debian12
    load_inventory
    [[ -s ${SECRETS} ]] || die "${SECRETS} ausente"
    detect_self
    flux_require_db
    ensure_git
    cmd_flux_src
    cmd_flux
}

gen_only() {
    load_inventory
    detect_self
    [[ ${SELF} == gen ]] || die "acao do servidor de testes; este servidor e ${SELF}"
}

# --------------------------------------------------------------- check (somente leitura)
chk() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        printf '  ok    %s\n' "${label}"
    else
        printf '  FALHA %s\n' "${label}"
        CHECK_FAIL=$((CHECK_FAIL + 1))
    fi
}

info() { printf '  info  %s\n' "$*"; }

cmd_check() {
    local r v
    CHECK_FAIL=0
    valid_roles
    printf '== %s\n' "$(hostname)"
    chk "usuario loadtest" id loadtest
    v=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    [[ ${v} == yes ]] && info "relogio sincronizado (NTP)" || printf '  AVISO relogio sem NTP sincronizado\n'
    for r in "${ROLES[@]}"; do
        printf -- '-- %s\n' "${r}"
        case "${r}" in
            freeswitch)
                chk "servico freeswitch ativo" systemctl is-active --quiet freeswitch
                chk "fs_cli responde (root)" fs_cli -x status
                chk "sudoers do loadtest com fs_cli" grep -qs fs_cli /etc/sudoers.d/flux-loadtest
                v=$(fs_cli -x 'sofia status' 2>/dev/null | awk '$2 == "profile" { printf "%s=%s ", $1, $4 }') || true
                [[ -n ${v} ]] && info "perfis: ${v}"
                ;;
            opensips)
                chk "servico opensips ativo" systemctl is-active --quiet opensips
                chk "opensips-cli mi version" opensips-cli -x mi version
                chk "sudoers do loadtest com opensips-cli" grep -qs opensips-cli /etc/sudoers.d/flux-loadtest
                ;;
            mysql)
                chk "mysqld responde" mysqladmin ping
                v=$(mysql -N -B -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment')" 2>/dev/null | awk '{ printf "%s=%s ", $1, $2 }') || true
                [[ -n ${v} ]] && info "${v}"
                chk "credencial de coleta /etc/mysql/flux-loadtest.cnf (loadtest)" \
                    runuser -u loadtest -- mysql --defaults-extra-file=/etc/mysql/flux-loadtest.cnf -N -B -e 'SELECT 1'
                ;;
            web)
                chk "servico nginx ativo" systemctl is-active --quiet nginx
                chk "servico php7.3-fpm ativo" systemctl is-active --quiet php7.3-fpm
                chk "nginx_status em 127.0.0.1 (opcional)" curl -fsS -m 3 http://127.0.0.1/nginx_status
                chk "fpm-status em 127.0.0.1 (opcional)" curl -fsS -m 3 'http://127.0.0.1/fpm-status?json'
                ;;
            zabbix-agent)
                chk "servico zabbix-agent ativo" systemctl is-active --quiet zabbix-agent
                chk "wrapper /usr/local/sbin/flux-loadtest-zbx" test -x /usr/local/sbin/flux-loadtest-zbx
                chk "sudoers do usuario zabbix" visudo -cf /etc/sudoers.d/flux-loadtest-zbx
                chk "estado pelo usuario zabbix (sudo -n)" runuser -u zabbix -- sudo -n /usr/local/sbin/flux-loadtest-zbx state
                v=$(zabbix_agentd -t flt.profiles.discovery 2>/dev/null | sed -n 's/.*\[t|\(.*\)\]$/\1/p') || true
                [[ -n ${v} ]] && info "descoberta: ${v}"
                for v in Server ServerActive Include AllowKey DenyKey EnableRemoteCommands; do
                    zbx_agent_lines "${v}" | sed 's/^/  info  agentd: /'
                done
                ;;
            gen)
                chk "sipp" command -v sipp
                chk "wrk" command -v wrk
                chk "loadtest.conf" test -r /etc/flux-loadtest/loadtest.conf
                ;;
        esac
    done
    ((CHECK_FAIL == 0)) || { log "${CHECK_FAIL} verificacao(oes) com falha"; return 1; }
    log "todas as verificacoes ok"
}

# --------------------------------------------------------------- main
main() {
    local action=${1:-help}
    (($# > 0)) && shift
    while (($# > 0)); do
        case "$1" in
            -c)                  CONF_FILE=${2:?-c exige um arquivo}; shift 2 ;;
            --as)                SELF=${2:?--as exige um id}; shift 2 ;;
            --dry-run)           DRY_RUN=1; shift ;;
            -y)                  ASSUME_YES=1; shift ;;
            --monitor-pass-file) MONITOR_PASS_FILE=${2:?--monitor-pass-file exige um arquivo}; shift 2 ;;
            --create-db-user)    CREATE_DB_USER=1; shift ;;
            --apply-status)      APPLY_STATUS=1; shift ;;
            --zabbix-server)     ZBX_SERVER=${2:?--zabbix-server exige um IP}; shift 2 ;;
            -h|--help)           usage; return 0 ;;
            -*)                  usage >&2; die "opcao invalida: $1" ;;
            *)                   ROLES+=("$1"); shift ;;
        esac
    done
    case "${action}" in
        help|-h|--help) usage; return 0 ;;
    esac
    require_root
    case "${action}" in
        init)         cmd_init_host ;;
        lab)          cmd_lab ;;
        mysql-schema) cmd_mysql_schema ;;
        keys)         gen_only; cmd_keys ;;
        smoke)        gen_only; cmd_smoke ;;
        zabbix)       gen_only; cmd_zabbix ;;
        prepare)
            valid_roles
            require_debian12
            [[ -z ${ZBX_SERVER} || ${ZBX_SERVER} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(,[0-9]{1,3}(\.[0-9]{1,3}){3})*$ ]] \
                || die "--zabbix-server: IPv4 (ou lista separada por virgula)"
            cmd_prepare
            ;;
        check)        cmd_check || exit 1 ;;
        *)            usage >&2; die "acao invalida: ${action}" ;;
    esac
}

main "$@"
