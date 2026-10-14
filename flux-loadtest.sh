#!/usr/bin/env bash
#
# flux-loadtest.sh - teste de carga do FluxSBC (WEB-1437)
#
# Roda em uma VM separada e atua nos servidores por SSH:
#   OpenSIPS (1) -> load_balancer -> FreeSWITCH (2), MySQL 8.4 Percona (2), Web (1)
#
# Fases de um "run" (cada uma marcada no tempo para o relatorio):
#   baseline  so coleta, com o trafego real do ambiente
#   sip       SIPp envia INVITE para DIDs via OpenSIPS; com UAS_PORT, um segundo SIPp
#             nesta VM atende o bridge do FS (DIDs DIRECT-IP, call_type 2)
#   mysql     sysbench em schema isolado (opcional, --tests ...,mysql)
#   web_*     wrk no nginx (estatico) e no PHP-FPM (pagina PHP)
#   cooldown  so coleta, para ver o retorno ao normal
#
# Durante todas as fases, um coletor somente leitura (lib/collector.sh) roda
# em cada servidor via SSH e grava CPU, memoria, rede, disco e metricas do
# servico. Nada e instalado nos servidores.
#
# Limites de seguranca (guard): se CPU, memoria, disco, atraso de replicacao
# ou taxa de falha SIP passarem do limite por GUARD_HITS amostras seguidas,
# a carga para de forma suave e as fases seguintes sao canceladas.
#
# Zabbix (opcional, ZABBIX_SERVER): as amostras vao por trapper durante o run
# (lib/flux_zabbix.py) e uma execucao antiga pode ser importada com "zabbix send".
# Templates em zabbix/flux-loadtest-templates.yaml.
#
# Requisitos na VM de teste (Debian 12):
#   apt install sip-tester wrk openssh-client curl python3
#   apt install sysbench default-mysql-client     (somente para --tests mysql)

set -Eeuo pipefail
export LC_ALL=C

readonly VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly COLLECTOR="${SCRIPT_DIR}/lib/collector.sh"
readonly SCENARIO_TPL="${SCRIPT_DIR}/scenarios/uac-did.xml.in"
readonly UAS_TPL="${SCRIPT_DIR}/scenarios/uas-answer.xml.in"
# porta de controle do SIPp atendedor (o originador usa a padrao, 8888)
readonly UAS_CONTROL_PORT=8889
readonly ZBX_HELPER="${SCRIPT_DIR}/lib/flux_zabbix.py"
readonly ZBX_TEMPLATE="${SCRIPT_DIR}/zabbix/flux-loadtest-templates.yaml"
readonly UA="flux-loadtest/${VERSION}"

# Codigos de saida
readonly E_USAGE=2 E_CONFIG=3 E_DEPS=4 E_REMOTE=5 E_ABORT=6

log()  { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
warn() { printf '[%(%H:%M:%S)T] AVISO: %s\n' -1 "$*" >&2; }
die()  { local code=$1; shift; printf '[%(%H:%M:%S)T] ERRO: %s\n' -1 "$*" >&2; exit "${code}"; }

trap 'printf "[flux-loadtest] falha na linha %s: %s\n" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

# --------------------------------------------------------------- configuracao
declare -A CFG=(
    [SSH_USER]="" [SSH_KEY]="" [SSH_PORT]="22"
    [SSH_OPTS]="-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
    [SSH_KNOWN_HOSTS]="" [SSH_KEY_TYPE]="ed25519" [SSH_KEY_COMMENT]="" [SSH_KEY_FROM]=""
    [OPENSIPS_HOST]="" [FS_HOSTS]="" [DB_HOSTS]="" [WEB_HOST]=""
    [SIP_TARGET]="" [SIP_LOCAL_IP]="" [SIP_LOCAL_PORT]="5060"
    [DID_FILE]="" [CALLER_ID]="" [RTP_PORT_BASE]="20000" [SIP_RECV_TIMEOUT_MS]="60000"
    [UAS_PORT]="" [UAS_RTP_PORT_BASE]="40000"
    [FS_CLI_CMD]="fs_cli -x" [FS_CLI_PASSWORD_FILE]="" [FS_DISK_PATH]="/var/lib/freeswitch"
    [VM_BOXES]="" [VM_GREETING_SECONDS]="8" [VM_BYTES_PER_SECOND]="16000"
    [OPENSIPS_MI_CMD]="opensips-cli -x mi"
    [MYSQL_CLI_CMD]="mysql" [MYSQL_DISK_PATH]="/var/lib/mysql" [FLUX_DB_NAME]="flux" [DB_VIP]=""
    [NGINX_STATUS_URL]="" [FPM_STATUS_URL]="" [WEB_PROCS]="nginx,php-fpm"
    [WEB_BASE_URL]="" [WEB_STATIC_PATH]="/assets/images/addon_icon.png" [WEB_PHP_PATH]="/"
    [WEB_EXTRA_PATH]="" [WEB_TLS_INSECURE]="1" [WEB_REUSE_SESSION]="1" [WEB_SESSION_COOKIE]="ci_session"
    [MYSQL_BENCH_HOST]="" [MYSQL_BENCH_PORT]="3306" [MYSQL_BENCH_USER]=""
    [MYSQL_BENCH_PASSWORD_FILE]="" [MYSQL_BENCH_DB]="loadtest" [MYSQL_BENCH_TABLES]="4"
    [MYSQL_BENCH_TABLE_SIZE]="100000" [MYSQL_BENCH_THREADS]="8" [MYSQL_BENCH_EXTRA_ARGS]=""
    [GUARD_MAX_CPU_PCT]="85" [GUARD_MAX_GEN_CPU_PCT]="90" [GUARD_MAX_MEM_PCT]="90"
    [GUARD_MIN_DISK_FREE_PCT]="15" [GUARD_MAX_FAIL_PCT]="5" [GUARD_MAX_REPL_LAG]="30"
    [GUARD_MAX_CORE_PCT]="0" [GUARD_HITS]="3"
    [GUARD_MAX_WSREP_FC_PCT]="10" [GUARD_MIN_WSREP_CLUSTER_SIZE]="0"
    [SAMPLE_INTERVAL]="5" [BASELINE_SECONDS]="60" [COOLDOWN_SECONDS]="60"
    [RESULTS_DIR]="/var/lib/flux-loadtest/results"
    [ZABBIX_SERVER]="" [ZABBIX_PORT]="10051" [ZABBIX_HOST_PREFIX]="flt-" [ZABBIX_LIVE]="1"
    [ZABBIX_API_URL]="" [ZABBIX_API_TOKEN_FILE]="" [ZABBIX_TLS_INSECURE]="0"
)

load_config() {
    local file=$1 line key val n=0
    [[ -r ${file} ]] || die "${E_CONFIG}" "configuracao nao encontrada ou ilegivel: ${file} (copie loadtest.conf.example)"
    while IFS= read -r line || [[ -n ${line} ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ ${line} =~ ^[[:space:]]*(#|$) ]] && continue
        [[ ${line} =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "${E_CONFIG}" "${file}:${n}: linha invalida (use CHAVE=valor)"
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        [[ -n ${CFG[${key}]+x} ]] || die "${E_CONFIG}" "${file}:${n}: chave desconhecida: ${key}"
        if [[ ${val} =~ ^\"(.*)\"$ || ${val} =~ ^\'(.*)\'$ ]]; then
            val=${BASH_REMATCH[1]}
        fi
        CFG[${key}]=${val}
    done < "${file}"
}

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

require_cfg() {
    local key
    for key in "$@"; do
        [[ -n ${CFG[${key}]} ]] || die "${E_CONFIG}" "${key} nao definido na configuracao"
    done
}

validate_config() {
    local key
    for key in SSH_PORT SIP_LOCAL_PORT RTP_PORT_BASE SIP_RECV_TIMEOUT_MS VM_GREETING_SECONDS \
               VM_BYTES_PER_SECOND MYSQL_BENCH_PORT MYSQL_BENCH_TABLES MYSQL_BENCH_TABLE_SIZE \
               MYSQL_BENCH_THREADS GUARD_MAX_CPU_PCT GUARD_MAX_GEN_CPU_PCT GUARD_MAX_MEM_PCT \
               GUARD_MIN_DISK_FREE_PCT GUARD_MAX_FAIL_PCT GUARD_MAX_REPL_LAG GUARD_MAX_CORE_PCT \
               GUARD_HITS GUARD_MAX_WSREP_FC_PCT GUARD_MIN_WSREP_CLUSTER_SIZE \
               SAMPLE_INTERVAL BASELINE_SECONDS COOLDOWN_SECONDS ZABBIX_PORT UAS_RTP_PORT_BASE; do
        is_uint "${CFG[${key}]}" || die "${E_CONFIG}" "${key} deve ser inteiro: '${CFG[${key}]}'"
    done
    if [[ -n ${CFG[UAS_PORT]} ]]; then
        is_uint "${CFG[UAS_PORT]}" && ((CFG[UAS_PORT] >= 1 && CFG[UAS_PORT] <= 65535)) \
            || die "${E_CONFIG}" "UAS_PORT invalida: '${CFG[UAS_PORT]}'"
        ((CFG[UAS_PORT] != CFG[SIP_LOCAL_PORT])) || die "${E_CONFIG}" "UAS_PORT deve ser diferente de SIP_LOCAL_PORT"
        ((CFG[UAS_RTP_PORT_BASE] >= 1024 && CFG[UAS_RTP_PORT_BASE] <= 60000)) \
            || die "${E_CONFIG}" "UAS_RTP_PORT_BASE fora de 1024-60000"
        ((CFG[UAS_RTP_PORT_BASE] != CFG[RTP_PORT_BASE])) \
            || die "${E_CONFIG}" "UAS_RTP_PORT_BASE deve ser diferente de RTP_PORT_BASE"
    fi
    ((CFG[SAMPLE_INTERVAL] >= 1)) || die "${E_CONFIG}" "SAMPLE_INTERVAL minimo: 1"
    [[ ${CFG[SSH_KEY_TYPE]} == ed25519 || ${CFG[SSH_KEY_TYPE]} == rsa ]] \
        || die "${E_CONFIG}" "SSH_KEY_TYPE deve ser ed25519 ou rsa"
    [[ -z ${CFG[SSH_KNOWN_HOSTS]} || ${CFG[SSH_KNOWN_HOSTS]} == /* ]] \
        || die "${E_CONFIG}" "SSH_KNOWN_HOSTS deve ser caminho absoluto"
    [[ -z ${CFG[DB_VIP]} || ${CFG[DB_VIP]} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
        || die "${E_CONFIG}" "DB_VIP invalido: ${CFG[DB_VIP]}"
    [[ -z ${CFG[SSH_KEY_FROM]} || ${CFG[SSH_KEY_FROM]} =~ ^[0-9A-Fa-f.:/,*?]+$ ]] \
        || die "${E_CONFIG}" "SSH_KEY_FROM invalido (IPs/CIDR separados por virgula)"
    ((CFG[GUARD_HITS] >= 1)) || die "${E_CONFIG}" "GUARD_HITS minimo: 1"
    [[ ${CFG[RESULTS_DIR]} == /* ]] || die "${E_CONFIG}" "RESULTS_DIR deve ser caminho absoluto"
    [[ -z ${CFG[ZABBIX_SERVER]} || ${CFG[ZABBIX_SERVER]} =~ ^[A-Za-z0-9._:-]+$ ]] \
        || die "${E_CONFIG}" "ZABBIX_SERVER invalido: ${CFG[ZABBIX_SERVER]}"
    [[ ${CFG[ZABBIX_HOST_PREFIX]} =~ ^[A-Za-z0-9._-]{0,32}$ ]] \
        || die "${E_CONFIG}" "ZABBIX_HOST_PREFIX invalido (letras, numeros, . _ -)"
    [[ ${CFG[ZABBIX_LIVE]} == [01] && ${CFG[ZABBIX_TLS_INSECURE]} == [01] ]] \
        || die "${E_CONFIG}" "ZABBIX_LIVE e ZABBIX_TLS_INSECURE devem ser 0 ou 1"
    [[ -z ${CFG[ZABBIX_API_URL]} || ${CFG[ZABBIX_API_URL]} =~ ^https?://[^[:space:]]+$ ]] \
        || die "${E_CONFIG}" "ZABBIX_API_URL invalida: ${CFG[ZABBIX_API_URL]}"
    [[ -z ${CFG[ZABBIX_API_TOKEN_FILE]} || ${CFG[ZABBIX_API_TOKEN_FILE]} == /* ]] \
        || die "${E_CONFIG}" "ZABBIX_API_TOKEN_FILE deve ser caminho absoluto"
}

# --------------------------------------------------------------- servidores
HOST_IDS=()
declare -A HOST_ADDR=() HOST_ROLE=() HOST_NAME=()

add_host() {
    local id=$1 role=$2 addr=$3
    [[ ${addr} =~ ^[A-Za-z0-9._:-]+$ ]] || die "${E_CONFIG}" "endereco invalido para ${id}: '${addr}'"
    HOST_IDS+=("${id}")
    HOST_ADDR[${id}]=${addr}
    HOST_ROLE[${id}]=${role}
}

build_hosts() {
    local h i
    local -a list
    HOST_IDS=()
    [[ -n ${CFG[OPENSIPS_HOST]} ]] && add_host opensips opensips "${CFG[OPENSIPS_HOST]}"
    read -ra list <<< "${CFG[FS_HOSTS]}"
    i=0
    for h in "${list[@]}"; do i=$((i + 1)); add_host "fs${i}" fs "${h}"; done
    read -ra list <<< "${CFG[DB_HOSTS]}"
    i=0
    for h in "${list[@]}"; do i=$((i + 1)); add_host "db${i}" db "${h}"; done
    [[ -n ${CFG[WEB_HOST]} ]] && add_host web web "${CFG[WEB_HOST]}"
    ((${#HOST_IDS[@]} > 0)) || die "${E_CONFIG}" "nenhum servidor configurado (OPENSIPS_HOST, FS_HOSTS, DB_HOSTS, WEB_HOST)"
}

SSH_CMD=()
# build_ssh [exigir_chave=1]
build_ssh() {
    local need_key=${1:-1}
    local -a opts
    require_cfg SSH_USER
    read -ra opts <<< "${CFG[SSH_OPTS]}"
    SSH_CMD=(ssh -p "${CFG[SSH_PORT]}" "${opts[@]}")
    if [[ -n ${CFG[SSH_KNOWN_HOSTS]} ]]; then
        SSH_CMD+=(-o "UserKnownHostsFile=${CFG[SSH_KNOWN_HOSTS]}")
    fi
    if [[ -n ${CFG[SSH_KEY]} ]]; then
        if [[ -r ${CFG[SSH_KEY]} ]]; then
            SSH_CMD+=(-i "${CFG[SSH_KEY]}" -o IdentitiesOnly=yes)
        elif ((need_key)); then
            die "${E_CONFIG}" "SSH_KEY ilegivel: ${CFG[SSH_KEY]} (crie com: $0 keys create)"
        fi
    fi
}

# remote <id> <comando shell remoto>   (stdin desligado, timeout de 30 s)
remote() {
    local id=$1; shift
    timeout 30 "${SSH_CMD[@]}" -n "${CFG[SSH_USER]}@${HOST_ADDR[${id}]}" "$*"
}

# remote_script <id> <script bash>   (script pelo stdin: nao aparece na linha de comando)
remote_script() {
    local id=$1 script=$2
    printf '%s\n' "${script}" | timeout 30 "${SSH_CMD[@]}" -T "${CFG[SSH_USER]}@${HOST_ADDR[${id}]}" bash -s
}

# --------------------------------------------------------------- senha do fs_cli
# Origem: --fs-password (digitada) ou FS_CLI_PASSWORD_FILE (arquivo 0600 na VM).
# Vazia = fs_cli usa a propria configuracao (padrao ClueCon ou ~/.fs_cli_conf).
# Trafega so pelo stdin do SSH; nunca vai para argumentos do ssh, arquivos ou logs.
FS_CLI_PASSWORD=""
OPT_FS_PASSWORD_PROMPT=0

has_role() {
    local id
    for id in "${HOST_IDS[@]}"; do
        [[ ${HOST_ROLE[${id}]} == "$1" ]] && return 0
    done
    return 1
}

load_fs_password() {
    local file=${CFG[FS_CLI_PASSWORD_FILE]} mode line
    has_role fs || return 0
    if ((OPT_FS_PASSWORD_PROMPT)); then
        [[ -t 0 ]] || die "${E_USAGE}" "--fs-password exige terminal; use FS_CLI_PASSWORD_FILE"
        read -r -s -p "Senha do fs_cli (event socket): " FS_CLI_PASSWORD
        printf '\n' >&2
        [[ -n ${FS_CLI_PASSWORD} ]] || die "${E_USAGE}" "senha do fs_cli vazia"
    elif [[ -n ${file} ]]; then
        [[ -r ${file} ]] || die "${E_CONFIG}" "FS_CLI_PASSWORD_FILE ilegivel: ${file}"
        mode=$(stat -c '%a' "${file}" 2>/dev/null || echo "?")
        if [[ ${mode} =~ [0-7][1-7]$|[1-7][0-7]$ ]]; then
            warn "${file} com permissao ${mode}: use chmod 600 (a senha fica legivel para outros usuarios)"
        fi
        IFS= read -r line < "${file}" || true
        FS_CLI_PASSWORD=${line%$'\r'}
        [[ -n ${FS_CLI_PASSWORD} ]] || die "${E_CONFIG}" "FS_CLI_PASSWORD_FILE vazio: ${file}"
    else
        return 0
    fi
    local -a w
    read -ra w <<< "${CFG[FS_CLI_CMD]}"
    local x found=0
    for x in "${w[@]}"; do [[ ${x##*/} == fs_cli ]] && found=1; done
    ((found)) || die "${E_CONFIG}" "FS_CLI_CMD precisa conter o comando fs_cli para aplicar a senha: ${CFG[FS_CLI_CMD]}"
}

# Preambulo bash para os scripts remotos do FS: define fsx() = FS_CLI_CMD com -p.
fs_prelude() {
    local -a w
    local x out="" added=0
    read -ra w <<< "${CFG[FS_CLI_CMD]}"
    for x in "${w[@]}"; do
        out+="$(printf '%q' "${x}") "
        if ((added == 0)) && [[ -n ${FS_CLI_PASSWORD} && ${x##*/} == fs_cli ]]; then
            out+='-p "${FSPW}" '
            added=1
        fi
    done
    printf 'FSPW=%q\n' "${FS_CLI_PASSWORD}"
    printf 'fsx() { %s"$@"; }\n' "${out}"
}

# Argumentos do coletor por papel (sem o --max).
collector_args() {
    local role=$1
    COLL_ARGS=(--role "${role}" --interval "${CFG[SAMPLE_INTERVAL]}")
    case "${role}" in
        opensips) COLL_ARGS+=(--procs opensips --disk / --cmd "${CFG[OPENSIPS_MI_CMD]}") ;;
        fs)       COLL_ARGS+=(--procs freeswitch --disk "${CFG[FS_DISK_PATH]}" --cmd "${CFG[FS_CLI_CMD]}") ;;
        db)       COLL_ARGS+=(--procs mysqld --disk "${CFG[MYSQL_DISK_PATH]}" --cmd "${CFG[MYSQL_CLI_CMD]}")
                  [[ -n ${CFG[DB_VIP]} ]] && COLL_ARGS+=(--vip "${CFG[DB_VIP]}")
                  ;;
        web)      COLL_ARGS+=(--procs "${CFG[WEB_PROCS]}" --disk /)
                  [[ -n ${CFG[NGINX_STATUS_URL]} ]] && COLL_ARGS+=(--nginx-url "${CFG[NGINX_STATUS_URL]}")
                  [[ -n ${CFG[FPM_STATUS_URL]} ]] && COLL_ARGS+=(--fpm-url "${CFG[FPM_STATUS_URL]}")
                  ;;
        gen)      COLL_ARGS+=(--procs "sipp,wrk,sysbench" --disk "${CFG[RESULTS_DIR]}") ;;
    esac
}

# --------------------------------------------------------------- dependencias
check_local_deps() {
    local cmd
    local -a missing=()
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if ((${#missing[@]} > 0)); then
        die "${E_DEPS}" "comandos ausentes na VM de teste: ${missing[*]} (veja os requisitos no topo do script)"
    fi
    ((BASH_VERSINFO[0] >= 5)) || die "${E_DEPS}" "bash 5 ou superior necessario"
}

# --------------------------------------------------------------- SIP
SIP_TARGET_IP="" SIP_TARGET_PORT=""
parse_sip_target() {
    require_cfg SIP_TARGET
    [[ ${CFG[SIP_TARGET]} =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3})(:([0-9]+))?$ ]] \
        || die "${E_CONFIG}" "SIP_TARGET invalido (use IP:porta): ${CFG[SIP_TARGET]}"
    SIP_TARGET_IP=${BASH_REMATCH[1]}
    SIP_TARGET_PORT=${BASH_REMATCH[4]:-5060}
}

detect_local_ip() {
    if [[ -n ${CFG[SIP_LOCAL_IP]} ]]; then
        printf '%s' "${CFG[SIP_LOCAL_IP]}"
        return 0
    fi
    ip -o -4 route get "${SIP_TARGET_IP}" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

# calls.csv do SIPp: DIDs validos embaralhados; [field0]=DID [field1]=A
build_calls_csv() {
    local out=$1 single=${2:-} total valid
    require_cfg CALLER_ID
    [[ ${CFG[CALLER_ID]} =~ ^\+?[0-9]{4,20}$ ]] || die "${E_CONFIG}" "CALLER_ID invalido: ${CFG[CALLER_ID]}"
    if [[ -n ${single} ]]; then
        [[ ${single} =~ ^\+?[0-9]{4,20}$ ]] || die "${E_USAGE}" "DID invalido: ${single}"
        printf 'SEQUENTIAL\n%s;%s\n' "${single}" "${CFG[CALLER_ID]}" > "${out}"
        return 0
    fi
    require_cfg DID_FILE
    [[ -r ${CFG[DID_FILE]} ]] || die "${E_CONFIG}" "DID_FILE ilegivel: ${CFG[DID_FILE]}"
    # linhas vazias e comentarios (#) nao contam como invalidas
    total=$(tr -d '\r' < "${CFG[DID_FILE]}" | grep -cvE '^[[:space:]]*(#|$)' || true)
    {
        printf 'SEQUENTIAL\n'
        tr -d '\r' < "${CFG[DID_FILE]}" | grep -E '^\+?[0-9]{4,20}$' | shuf \
            | awk -v a="${CFG[CALLER_ID]}" '{ print $1 ";" a }'
    } > "${out}"
    valid=$(($(grep -c '' "${out}") - 1))
    ((valid > 0)) || die "${E_CONFIG}" "nenhum DID valido em ${CFG[DID_FILE]} (um numero por linha)"
    if ((valid < total)); then
        warn "${CFG[DID_FILE]}: $((total - valid)) linha(s) ignorada(s) por formato invalido"
    fi
    DID_COUNT=${valid}
}

# Tom G.711 a-law (400 Hz / 1 kHz alternados a cada 500 ms) em loop no rtp_stream.
# O tom evita que a deteccao de silencio da caixa postal encerre a gravacao.
build_rtp_file() {
    local out=$1
    python3 - "${out}" <<'PY'
import math, sys
SEG = (0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF)
def lin2alaw(v):
    v >>= 3
    mask = 0xD5 if v >= 0 else 0x55
    if v < 0:
        v = -v - 1
    seg = next((i for i, e in enumerate(SEG) if v <= e), 8)
    if seg >= 8:
        return 0x7F ^ mask
    return ((seg << 4) | (((v >> 1) if seg < 2 else (v >> seg)) & 0x0F)) ^ mask
rate = 8000
data = bytes(lin2alaw(int(8000 * math.sin(2 * math.pi * (400 if (n // 4000) % 2 == 0 else 1000) * n / rate)))
             for n in range(rate * 20))
with open(sys.argv[1], "wb") as f:
    f.write(data)
PY
}

# render_scenario MODELO SAIDA TEMPO_MS MIDIA [ARQUIVO_RTP]
# TEMPO_MS: hold do originador (@HOLD_MS@) ou espera do BYE no atendedor (@BYE_TIMEOUT_MS@)
render_scenario() {
    local tpl=$1 out=$2 time_ms=$3 media=$4 rtp_file=${5:-} media_port action=""
    [[ -r ${tpl} ]] || die "${E_DEPS}" "cenario nao encontrado: ${tpl}"
    if [[ ${media} == rtp ]]; then
        media_port='[rtpstream_audio_port]'
        action="<nop><action><exec rtp_stream=\"${rtp_file},-1,8\"/></action></nop>"
    else
        media_port='[media_port]'
    fi
    sed -e "s|@HOLD_MS@|${time_ms}|g" \
        -e "s|@BYE_TIMEOUT_MS@|${time_ms}|g" \
        -e "s|@MEDIA_PORT@|${media_port}|g" \
        -e "s|@RUN_ID@|${RUN_ID}|g" \
        -e "s|@RTP_ACTION@|${action}|g" \
        "${tpl}" > "${out}"
}

# --------------------------------------------------------------- atendedor (UAS)
# Com UAS_PORT definido, um segundo SIPp nesta VM atende as chamadas que o FS entrega
# aos DIDs DIRECT-IP (dids.call_type = 2, extensions = IP desta VM:UAS_PORT). Assim a
# chamada percorre OpenSIPS, load_balancer, dialplan Lua, MySQL e o bridge com midia
# nos dois sentidos, sem depender de ramal registrado nem de caixa postal.
UAS_PID=""
UAS_ARGS=()

uas_enabled() { [[ -n ${CFG[UAS_PORT]} ]]; }

# Porta UDP do atendedor livre nesta VM (ss do iproute2)
uas_port_free() {
    [[ -z $(ss -Hlun "sport = :${CFG[UAS_PORT]}" 2>/dev/null) ]]
}

# -aa responde 200 a INFO/NOTIFY/OPTIONS/UPDATE fora do cenario; -timeout e so trava de
# seguranca (o atendedor e encerrado pelo stop_uas ao fim da fase sip)
uas_args() {
    local dir=$1 local_ip=$2
    UAS_ARGS=(-sf "${dir}/uas.xml" -i "${local_ip}" -p "${CFG[UAS_PORT]}" -t u1 -nostdin -aa
        -cp "${UAS_CONTROL_PORT}" -mp "${CFG[UAS_RTP_PORT_BASE]}" -buff_size 4194304
        -timeout $((OPT_WINDOW + OPT_HOLD + 300))
        -trace_stat -stf "${dir}/stats.csv" -fd "${CFG[SAMPLE_INTERVAL]}"
        -trace_err -error_file "${dir}/errors.log")
}

prepare_uas() {
    local dir=$1 local_ip=$2 rtp_file=$3
    uas_enabled || return 0
    mkdir -p "${dir}"
    # o BYE chega ao fim do hold; a margem cobre a rampa de encerramento e o leg_timeout
    render_scenario "${UAS_TPL}" "${dir}/uas.xml" $(((OPT_HOLD + 120) * 1000)) "${OPT_MEDIA}" "${rtp_file}"
    uas_args "${dir}" "${local_ip}"
}

start_uas() {
    local dir=$1 i
    uas_enabled || return 0
    (cd "${dir}" && exec sipp "${UAS_ARGS[@]}" > /dev/null 2> "${dir}/sipp.stderr") &
    UAS_PID=$!
    # espera o bind da porta; se o SIPp sair, a causa fica no stderr
    for ((i = 0; i < 10; i++)); do
        kill -0 "${UAS_PID}" 2>/dev/null || break
        uas_port_free || break
        sleep 0.5 || true
    done
    if ! kill -0 "${UAS_PID}" 2>/dev/null; then
        UAS_PID=""
        die "${E_DEPS}" "atendedor SIPp nao subiu em ${CFG[UAS_PORT]}/udp: $(sip_real_errors "${dir}/sipp.stderr" | head -c 300)"
    fi
    log "atendedor SIPp (UAS) ativo em ${LOCAL_IP}:${CFG[UAS_PORT]} (pid ${UAS_PID}, midia ${OPT_MEDIA})"
}

# Saida suave (SIGUSR1, uma vez): sem chamadas abertas o SIPp grava as estatisticas
# finais e sai. As chamadas do atendedor terminam com o BYE que o FS repassa.
stop_uas() {
    local i
    [[ -n ${UAS_PID} ]] || return 0
    if kill -0 "${UAS_PID}" 2>/dev/null; then
        kill -USR1 "${UAS_PID}" 2>/dev/null || true
        for ((i = 0; i < 30; i++)); do
            kill -0 "${UAS_PID}" 2>/dev/null || break
            sleep 0.5 || true
        done
        if kill -0 "${UAS_PID}" 2>/dev/null; then
            warn "atendedor SIPp nao encerrou em 15 s; enviando SIGTERM"
            kill -TERM "${UAS_PID}" 2>/dev/null || true
        fi
    fi
    wait "${UAS_PID}" 2>/dev/null || true
    UAS_PID=""
    log "atendedor SIPp encerrado"
}

# --------------------------------------------------------------- execucao
CONFIG_FILE=""
RUN_ID=""
RUN_DIR=""
PHASE_NAME=""
PHASE_START=0
ABORT_REASON=""
INTERRUPTED=0
REPORT_DONE=0
SIPP_PID=""
SIPP_SOFT_SENT=0
LOAD_PID=""
ZBX_PID=""
declare -A COLLECTOR_PID=()
declare -A GUARD_COUNT=()
declare -A STALE_WARNED=()

now() { printf '%(%s)T' -1; }

phase_begin() {
    PHASE_NAME=$1
    PHASE_START=$(now)
    # inicio das fases para o envio ao vivo (phases.tsv so recebe a fase concluida)
    printf '%s\t%s\n' "${PHASE_NAME}" "${PHASE_START}" >> "${RUN_DIR}/phases-start.tsv"
    log "fase ${PHASE_NAME}: inicio"
}

phase_end() {
    [[ -n ${PHASE_NAME} ]] || return 0
    printf '%s\t%s\t%s\n' "${PHASE_NAME}" "${PHASE_START}" "$(now)" >> "${RUN_DIR}/phases.tsv"
    log "fase ${PHASE_NAME}: fim"
    PHASE_NAME=""
}

# Espera N segundos em passos de 1 s; retorna cedo se a execucao for abortada.
wait_seconds() {
    local n=$1 i
    for ((i = 0; i < n; i++)); do
        [[ -z ${ABORT_REASON} ]] || return 0
        sleep 1 || true
    done
}

start_collectors() {
    local max=$1 id q
    mkdir -p "${RUN_DIR}/metrics"
    for id in "${HOST_IDS[@]}"; do
        collector_args "${HOST_ROLE[${id}]}"
        printf -v q '%q ' "${COLL_ARGS[@]}" --max "${max}"
        # A senha do fs_cli vai como 1a linha do script no stdin (nunca no argumento do ssh).
        {
            if [[ ${HOST_ROLE[${id}]} == fs ]]; then
                printf 'FS_CLI_PASSWORD=%q\n' "${FS_CLI_PASSWORD}"
            fi
            cat "${COLLECTOR}"
        } | "${SSH_CMD[@]}" -T "${CFG[SSH_USER]}@${HOST_ADDR[${id}]}" "nice -n 10 bash -s -- ${q}" \
            > "${RUN_DIR}/metrics/${id}.csv" 2> "${RUN_DIR}/metrics/${id}.err" &
        COLLECTOR_PID[${id}]=$!
    done
    collector_args gen
    nice -n 10 bash "${COLLECTOR}" "${COLL_ARGS[@]}" --max "${max}" \
        > "${RUN_DIR}/metrics/gen.csv" 2> "${RUN_DIR}/metrics/gen.err" &
    COLLECTOR_PID[gen]=$!
    log "coletores iniciados (${#COLLECTOR_PID[@]}), intervalo ${CFG[SAMPLE_INTERVAL]} s"
}

stop_collectors() {
    local id pid
    for id in "${!COLLECTOR_PID[@]}"; do
        pid=${COLLECTOR_PID[${id}]}
        kill "${pid}" 2>/dev/null || true
    done
    for id in "${!COLLECTOR_PID[@]}"; do
        wait "${COLLECTOR_PID[${id}]}" 2>/dev/null || true
        if [[ -s ${RUN_DIR}/metrics/${id}.err ]]; then
            warn "coletor ${id}: $(head -c 300 "${RUN_DIR}/metrics/${id}.err" | tr '\n' ' ')"
        fi
    done
    COLLECTOR_PID=()
}

# Ultima linha completa de um CSV do coletor -> "ts viol..." (violacoes de limite).
host_violations() {
    local id=$1 role=$2 file="${RUN_DIR}/metrics/${1}.csv" maxcpu
    [[ -s ${file} ]] || return 0
    maxcpu=${CFG[GUARD_MAX_CPU_PCT]}
    [[ ${role} == gen ]] && maxcpu=${CFG[GUARD_MAX_GEN_CPU_PCT]}
    awk -F, -v maxcpu="${maxcpu}" -v maxmem="${CFG[GUARD_MAX_MEM_PCT]}" \
        -v mindisk="${CFG[GUARD_MIN_DISK_FREE_PCT]}" -v maxcore="${CFG[GUARD_MAX_CORE_PCT]}" \
        -v maxlag="${CFG[GUARD_MAX_REPL_LAG]}" -v maxfc="${CFG[GUARD_MAX_WSREP_FC_PCT]}" \
        -v minsize="${CFG[GUARD_MIN_WSREP_CLUSTER_SIZE]}" '
        NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; n = NF; next }
        NF == n { l = $0 }
        function g(k,   x) { x = (k in c) ? v[c[k]] : ""; return x }
        END {
            if (l == "") exit
            split(l, v, ",")
            out = g("ts")
            if (g("cpu_pct") != "" && g("cpu_pct") + 0 > maxcpu) out = out " cpu=" g("cpu_pct")
            if (g("mem_used_pct") != "" && g("mem_used_pct") + 0 > maxmem) out = out " mem=" g("mem_used_pct")
            if (g("disk_free_pct") != "" && g("disk_free_pct") + 0 < mindisk) out = out " disco_livre=" g("disk_free_pct")
            if (maxcore > 0 && g("cpu_max_core_pct") + 0 > maxcore) out = out " nucleo=" g("cpu_max_core_pct")
            if (g("db_repl_lag") != "" && g("db_repl_lag") + 0 > maxlag) out = out " replicacao=" g("db_repl_lag") "s"
            if (g("db_repl_ok") == "0") out = out " replicacao_parada=1"
            # Percona XtraDB Cluster: 4 = Synced; Primary = no com quorum
            if (g("db_wsrep_state") != "" && g("db_wsrep_state") != "4") out = out " wsrep_estado=" g("db_wsrep_state")
            if (g("db_wsrep_primary") == "0") out = out " wsrep_sem_quorum=1"
            if (maxfc > 0 && g("db_wsrep_fc_paused_pct") != "" && g("db_wsrep_fc_paused_pct") + 0 > maxfc) out = out " flow_control=" g("db_wsrep_fc_paused_pct") "%"
            if (minsize > 0 && g("db_wsrep_cluster_size") != "" && g("db_wsrep_cluster_size") + 0 < minsize) out = out " cluster_size=" g("db_wsrep_cluster_size")
            print out
        }' "${file}"
}

# Taxa de falha SIP no ultimo periodo do -trace_stat (P), em percentual inteiro.
sip_fail_pct() {
    local file="${RUN_DIR}/sip/stats.csv"
    [[ -s ${file} ]] || return 0
    awk -F';' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } { l = $0 }
        END {
            if (l == "" || !("FailedCall(P)" in c)) exit
            split(l, v, ";")
            f = v[c["FailedCall(P)"]] + 0; s = v[c["SuccessfulCall(P)"]] + 0
            if (f + s >= 10) printf "%d %d %d\n", f * 100 / (f + s), f, f + s
        }' "${file}"
}

# Avalia os limites; preenche ABORT_REASON quando algum estoura GUARD_HITS vezes seguidas.
guard_check() {
    local with_sip=${1:-0} id line ts key metric now_ts metrics_rest
    local -A current=()
    now_ts=$(now)
    for id in "${HOST_IDS[@]}" gen; do
        local role=${HOST_ROLE[${id}]:-gen}
        line=$(host_violations "${id}" "${role}") || true
        [[ -n ${line} ]] || continue
        read -r ts metrics_rest <<< "${line} "
        if ((now_ts - ts > CFG[SAMPLE_INTERVAL] * 4)) && [[ -z ${STALE_WARNED[${id}]:-} ]]; then
            warn "coletor ${id} sem dados novos ha $((now_ts - ts)) s (verifique ${RUN_DIR}/metrics/${id}.err)"
            STALE_WARNED[${id}]=1
        fi
        for metric in ${metrics_rest}; do
            current["${id}:${metric%%=*}"]="${metric#*=}"
        done
    done
    if ((with_sip)); then
        line=$(sip_fail_pct) || true
        if [[ -n ${line} ]]; then
            local pct fails total
            read -r pct fails total <<< "${line}"
            if ((pct > CFG[GUARD_MAX_FAIL_PCT])); then
                current["sip:falha_pct"]="${pct}% (${fails}/${total})"
            fi
        fi
    fi
    for key in "${!GUARD_COUNT[@]}"; do
        [[ -n ${current[${key}]+x} ]] || unset 'GUARD_COUNT[${key}]'
    done
    for key in "${!current[@]}"; do
        GUARD_COUNT[${key}]=$(( ${GUARD_COUNT[${key}]:-0} + 1 ))
        printf '%s\t%s\t%s=%s\t%d/%d\n' "$(now)" "${PHASE_NAME}" "${key}" "${current[${key}]}" \
            "${GUARD_COUNT[${key}]}" "${CFG[GUARD_HITS]}" >> "${RUN_DIR}/guard.log"
        if ((GUARD_COUNT[${key}] >= CFG[GUARD_HITS])) && [[ -z ${ABORT_REASON} ]]; then
            ABORT_REASON="limite excedido: ${key}=${current[${key}]} por ${GUARD_COUNT[${key}]} amostras seguidas"
            warn "${ABORT_REASON}"
        fi
    done
}

# Saida suave do SIPp: para de criar chamadas e espera as ativas.
# Enviar UMA vez: no SIPp 3.6.1 um segundo SIGUSR1 deixa o processo travado.
sipp_soft_stop() {
    ((SIPP_SOFT_SENT == 0)) || return 0
    if [[ -n ${SIPP_PID} ]] && kill -0 "${SIPP_PID}" 2>/dev/null; then
        kill -USR1 "${SIPP_PID}" 2>/dev/null || true
        SIPP_SOFT_SENT=1
    fi
}

# Para a carga em andamento: SIPp com SIGUSR1 (saida suave), wrk/sysbench com SIGTERM.
stop_load() {
    sipp_soft_stop
    if [[ -n ${LOAD_PID} ]] && kill -0 "${LOAD_PID}" 2>/dev/null; then
        kill -TERM "${LOAD_PID}" 2>/dev/null || true
    fi
}

on_interrupt() {
    if ((INTERRUPTED)); then
        warn "segunda interrupcao: encerrando a carga imediatamente"
        [[ -n ${SIPP_PID} ]] && kill -TERM "${SIPP_PID}" 2>/dev/null
        [[ -n ${UAS_PID} ]] && kill -TERM "${UAS_PID}" 2>/dev/null
        [[ -n ${LOAD_PID} ]] && kill -TERM "${LOAD_PID}" 2>/dev/null
        exit "${E_ABORT}"
    fi
    INTERRUPTED=1
    [[ -n ${ABORT_REASON} ]] || ABORT_REASON="interrompido pelo operador"
    warn "interrompido: parando a carga de forma suave (Ctrl+C de novo para forcar)"
    stop_load
}

on_exit() {
    local rc=$?
    trap - ERR
    if [[ -n ${SIPP_PID} ]] && kill -0 "${SIPP_PID}" 2>/dev/null; then
        kill -TERM "${SIPP_PID}" 2>/dev/null || true
    fi
    if [[ -n ${UAS_PID} ]] && kill -0 "${UAS_PID}" 2>/dev/null; then
        kill -TERM "${UAS_PID}" 2>/dev/null || true
    fi
    if [[ -n ${LOAD_PID} ]] && kill -0 "${LOAD_PID}" 2>/dev/null; then
        kill -TERM "${LOAD_PID}" 2>/dev/null || true
    fi
    if ((${#COLLECTOR_PID[@]} > 0)); then
        phase_end
        stop_collectors
    fi
    if [[ -n ${RUN_DIR} && -d ${RUN_DIR} ]] && ((REPORT_DONE == 0)); then
        generate_report "${RUN_DIR}" || warn "falha ao gerar o relatorio parcial"
    fi
    zabbix_live_stop
    exit "${rc}"
}

snapshot() {
    local tag=$1 id role out cmd mi my b
    mkdir -p "${RUN_DIR}/snapshots"
    for id in "${HOST_IDS[@]}"; do
        role=${HOST_ROLE[${id}]}
        out="${RUN_DIR}/snapshots/${id}-${tag}.txt"
        cmd="echo '== sistema'; uname -n; uptime; nproc; free -m; df -hP"
        case "${role}" in
            fs)
                cmd="$(fs_prelude)"$'\n'"${cmd}"
                cmd+="; echo '== freeswitch'; fsx status; fsx 'show calls count'; fsx 'sofia status'"
                for b in ${CFG[VM_BOXES]}; do
                    [[ ${b} =~ ^[A-Za-z0-9._@-]+$ ]] || continue
                    cmd+="; echo '== vm_boxcount ${b}'; fsx 'vm_boxcount ${b}|all'"
                done
                ;;
            opensips)
                mi=${CFG[OPENSIPS_MI_CMD]}
                cmd+="; echo '== lb_list'; ${mi} lb_list; echo '== estatisticas'; ${mi} get_statistics dialog: tm: core: shmem: load:"
                ;;
            db)
                my=${CFG[MYSQL_CLI_CMD]}
                cmd+="; echo '== replica'; ${my} -e 'SHOW REPLICA STATUS\G'"
                cmd+="; echo '== variaveis'; ${my} -N -e 'SELECT @@version, @@max_connections, @@innodb_buffer_pool_size, @@wsrep_on' 2>/dev/null || ${my} -N -e 'SELECT @@version, @@max_connections, @@innodb_buffer_pool_size'"
                cmd+="; echo '== threads'; ${my} -N -e \"SHOW GLOBAL STATUS LIKE 'Threads_%'\""
                cmd+="; echo '== cluster (wsrep)'; ${my} -N -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready','wsrep_connected','wsrep_flow_control_paused','wsrep_local_recv_queue_avg','wsrep_local_send_queue_avg')\""
                [[ -n ${CFG[DB_VIP]} ]] && cmd+="; echo '== VIP ${CFG[DB_VIP]}'; ip -o -4 addr show | grep -q ' ${CFG[DB_VIP]}/' && echo 'ativo neste no' || echo 'em outro no'"
                ;;
            web)
                [[ -n ${CFG[NGINX_STATUS_URL]} ]] && cmd+="; echo '== nginx'; curl -fsk -m 3 $(printf '%q' "${CFG[NGINX_STATUS_URL]}")"
                [[ -n ${CFG[FPM_STATUS_URL]} ]] && cmd+="; echo '== php-fpm'; curl -fsk -m 3 $(printf '%q' "${CFG[FPM_STATUS_URL]}")"
                ;;
        esac
        remote_script "${id}" "${cmd}" > "${out}" 2>&1 || printf '\n(falha parcial na coleta do snapshot)\n' >> "${out}"
    done
    log "snapshots ${tag} salvos"
}

# --------------------------------------------------------------- Zabbix
zbx_enabled() { [[ -n ${CFG[ZABBIX_SERVER]} ]]; }

zbx_trap_args() {
    ZBX_ARGS=(--server "${CFG[ZABBIX_SERVER]}" --port "${CFG[ZABBIX_PORT]}" --prefix "${CFG[ZABBIX_HOST_PREFIX]}")
}

zbx_api_args() {
    require_cfg ZABBIX_API_URL ZABBIX_API_TOKEN_FILE
    ZBX_ARGS=(--api-url "${CFG[ZABBIX_API_URL]}" --token-file "${CFG[ZABBIX_API_TOKEN_FILE]}")
    [[ ${CFG[ZABBIX_TLS_INSECURE]} == 1 ]] && ZBX_ARGS+=(--insecure)
    return 0
}

# Envio ao vivo: o helper acompanha o RUN_DIR e encerra com SIGTERM (ou se este
# processo morrer). Falha no Zabbix nao interrompe o teste: so vai para zabbix.log.
zabbix_live_start() {
    zbx_enabled && [[ ${CFG[ZABBIX_LIVE]} == 1 ]] || return 0
    zbx_trap_args
    python3 "${ZBX_HELPER}" send "${RUN_DIR}" --follow --pid "$$" "${ZBX_ARGS[@]}" \
        >> "${RUN_DIR}/zabbix.log" 2>&1 &
    ZBX_PID=$!
    log "envio ao vivo para o Zabbix ${CFG[ZABBIX_SERVER]}:${CFG[ZABBIX_PORT]} (pid ${ZBX_PID}, log zabbix.log)"
}

zabbix_live_stop() {
    [[ -n ${ZBX_PID} ]] || return 0
    local pid=${ZBX_PID} i
    ZBX_PID=""
    kill -TERM "${pid}" 2>/dev/null || true
    for ((i = 0; i < 60; i++)); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill -KILL "${pid}" 2>/dev/null || true
        warn "envio ao Zabbix nao terminou em 60 s; reenvie com: $0 zabbix send ${RUN_DIR} --force"
    fi
    wait "${pid}" 2>/dev/null || warn "envio ao Zabbix com falhas: $(tail -n 1 "${RUN_DIR}/zabbix.log" 2>/dev/null)"
    log "zabbix: $(grep -o 'enviados .*' "${RUN_DIR}/zabbix.log" 2>/dev/null | tail -n 1)"
}

usage_zabbix() {
    cat <<EOF
Uso: $0 zabbix <sub> [opcoes] [-c ARQUIVO]

  setup [--import-template]  cria o grupo "Flux Loadtest" e os hosts <ZABBIX_HOST_PREFIX><id>
                             (servidores da configuracao + gen + run) e vincula os templates.
                             --import-template importa antes ${ZBX_TEMPLATE#"${SCRIPT_DIR}/"}
  send <diretorio> [--force] [--dry-run]
                             importa uma execucao com os timestamps originais (--force reenvia
                             uma execucao ja enviada; --dry-run so mostra os valores)
  check                      testa a API (ZABBIX_API_URL) e o trapper (ZABBIX_SERVER)
EOF
}

cmd_zabbix() {
    local sub=${1:-} opt import=0 force=0 dry=0 dir="" id
    (($# > 0)) && shift
    check_local_deps python3
    case "${sub}" in
        setup)
            for opt in "$@"; do
                case "${opt}" in
                    --import-template) import=1 ;;
                    *) usage_zabbix >&2; die "${E_USAGE}" "opcao invalida para zabbix setup: ${opt}" ;;
                esac
            done
            build_hosts
            zbx_api_args
            ZBX_ARGS+=(--prefix "${CFG[ZABBIX_HOST_PREFIX]}" --gen-cpu-max "${CFG[GUARD_MAX_GEN_CPU_PCT]}")
            ((import)) && ZBX_ARGS+=(--template "${ZBX_TEMPLATE}")
            for id in "${HOST_IDS[@]}"; do
                ZBX_ARGS+=(--host "${id}:${HOST_ROLE[${id}]}:${HOST_ADDR[${id}]}")
            done
            ZBX_ARGS+=(--host "gen:gen::vm-teste")
            python3 "${ZBX_HELPER}" setup "${ZBX_ARGS[@]}"
            ;;
        send)
            for opt in "$@"; do
                case "${opt}" in
                    --force) force=1 ;;
                    --dry-run) dry=1 ;;
                    -*) usage_zabbix >&2; die "${E_USAGE}" "opcao invalida para zabbix send: ${opt}" ;;
                    *) [[ -z ${dir} ]] || die "${E_USAGE}" "informe um unico diretorio"; dir=${opt%/} ;;
                esac
            done
            [[ -n ${dir} ]] || { usage_zabbix >&2; die "${E_USAGE}" "informe o diretorio da execucao"; }
            [[ -d ${dir} ]] || die "${E_USAGE}" "diretorio de resultado inexistente: ${dir}"
            ((dry)) || zbx_enabled || die "${E_CONFIG}" "ZABBIX_SERVER nao definido"
            zbx_trap_args
            ((force)) && ZBX_ARGS+=(--force)
            ((dry)) && ZBX_ARGS+=(--dry-run)
            python3 "${ZBX_HELPER}" send "${dir}" "${ZBX_ARGS[@]}"
            ;;
        check)
            local -a args=()
            if [[ -n ${CFG[ZABBIX_API_URL]} ]]; then
                args+=(--api-url "${CFG[ZABBIX_API_URL]}")
                [[ -n ${CFG[ZABBIX_API_TOKEN_FILE]} ]] && args+=(--token-file "${CFG[ZABBIX_API_TOKEN_FILE]}")
                [[ ${CFG[ZABBIX_TLS_INSECURE]} == 1 ]] && args+=(--insecure)
            fi
            zbx_trap_args
            zbx_enabled || ZBX_ARGS=(--prefix "${CFG[ZABBIX_HOST_PREFIX]}")
            ((${#args[@]} > 0)) || zbx_enabled || die "${E_CONFIG}" "defina ZABBIX_SERVER e/ou ZABBIX_API_URL"
            python3 "${ZBX_HELPER}" check "${args[@]+"${args[@]}"}" "${ZBX_ARGS[@]}"
            ;;
        ""|-h|--help) usage_zabbix ;;
        *) usage_zabbix >&2; die "${E_USAGE}" "subcomando invalido: zabbix ${sub}" ;;
    esac
}

# --------------------------------------------------------------- fases de carga
OPT_WINDOW=300 OPT_CALLS=0 OPT_CPS="" OPT_CPS_START="" OPT_RAMP_STEP="" OPT_RAMP_INTERVAL=10
OPT_LIMIT="" OPT_HOLD=30 OPT_MEDIA=rtp OPT_TESTS="sip,web" OPT_LABEL=""
OPT_WEB_DURATION=30 OPT_WEB_CONNS=50 OPT_WEB_THREADS=4 OPT_MYSQL_DURATION=60
OPT_BASELINE="" OPT_COOLDOWN="" OPT_CONFIRM_PROD=0 OPT_YES=0 OPT_DRY_RUN=0 OPT_DID=""
DID_COUNT=0

has_test() { [[ ",${OPT_TESTS}," == *",$1,"* ]]; }

sipp_args() {
    local dir=$1 local_ip=$2 hard_timeout
    hard_timeout=$((OPT_WINDOW + OPT_HOLD + 120))
    SIPP_ARGS=("${SIP_TARGET_IP}:${SIP_TARGET_PORT}"
        -sf "${dir}/uac-did.xml" -inf "${dir}/calls.csv"
        -i "${local_ip}" -p "${CFG[SIP_LOCAL_PORT]}" -t u1 -nostdin
        -l "${OPT_LIMIT}" -mp "${CFG[RTP_PORT_BASE]}"
        -recv_timeout "${CFG[SIP_RECV_TIMEOUT_MS]}" -timeout "${hard_timeout}"
        -buff_size 4194304
        -trace_stat -stf "${dir}/stats.csv" -fd "${CFG[SAMPLE_INTERVAL]}"
        -trace_err -error_file "${dir}/errors.log"
        -trace_screen -screen_file "${dir}/screen.log"
        -trace_logs -log_file "${dir}/actions.log")
    if ((OPT_CPS_START < OPT_CPS)); then
        SIPP_ARGS+=(-r "${OPT_CPS_START}" -rate_increase "${OPT_RAMP_STEP}"
            -rate_interval "${OPT_RAMP_INTERVAL}" -rate_max "${OPT_CPS}" -no_rate_quit)
    else
        SIPP_ARGS+=(-r "${OPT_CPS}")
    fi
    ((OPT_CALLS > 0)) && SIPP_ARGS+=(-m "${OPT_CALLS}")
    return 0
}

prepare_sip() {
    local dir=$1 local_ip=$2
    mkdir -p "${dir}"
    build_calls_csv "${dir}/calls.csv" "${OPT_DID}"
    if [[ ${OPT_MEDIA} == rtp ]]; then
        build_rtp_file "${dir}/tone.al"
    fi
    render_scenario "${SCENARIO_TPL}" "${dir}/uac-did.xml" $((OPT_HOLD * 1000)) "${OPT_MEDIA}" "${dir}/tone.al"
    sipp_args "${dir}" "${local_ip}"
}

raise_nofile() {
    local want=$1 cur
    ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
    cur=$(ulimit -n)
    if [[ ${cur} != unlimited ]] && ((cur < want)); then
        warn "ulimit -n = ${cur}, abaixo do recomendado (${want}) para ${OPT_LIMIT} chamadas simultaneas"
    fi
}

# Todas as chamadas criadas ja terminaram? Usa so as estatisticas do SIPp, que contam
# cada chamada uma vez: nenhuma ativa e sucesso + falha >= criadas. (O actions.log nao
# serve: uma chamada que registra LOCAL_BYE e depois falha no BYE contaria duas vezes.)
# Se o SIPp travar e parar de gravar estatisticas, vale a trava de hold + 60 s.
sip_all_done() {
    local stats="${RUN_DIR}/sip/stats.csv"
    [[ -s ${stats} ]] || return 1
    awk -F';' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } { l = $0 }
        END {
            if (l == "") exit 1
            split(l, v, ";")
            t = v[c["TotalCallCreated"]] + 0
            exit !(t > 0 && v[c["CurrentCall"]] + 0 == 0 && v[c["SuccessfulCall(C)"]] + v[c["FailedCall(C)"]] >= t)
        }' "${stats}"
}

run_sip_phase() {
    local dir="${RUN_DIR}/sip" local_ip=$1 t_end soft_at=0 rc=0
    raise_nofile $((OPT_LIMIT * 3 + 1024))
    phase_begin sip
    start_uas "${RUN_DIR}/uas"
    (cd "${dir}" && exec sipp "${SIPP_ARGS[@]}" > /dev/null 2> "${dir}/sipp.stderr") &
    SIPP_PID=$!
    SIPP_SOFT_SENT=0
    t_end=$(( $(now) + OPT_WINDOW ))
    log "SIPp iniciado (pid ${SIPP_PID}): alvo ${OPT_CPS} CPS, janela ${OPT_WINDOW} s, hold ${OPT_HOLD} s"

    while kill -0 "${SIPP_PID}" 2>/dev/null; do
        sleep "${CFG[SAMPLE_INTERVAL]}" || true
        kill -0 "${SIPP_PID}" 2>/dev/null || break
        if ((soft_at == 0)); then
            guard_check 1
            if [[ -n ${ABORT_REASON} ]] || (( $(now) >= t_end )); then
                sipp_soft_stop
                soft_at=$(now)
                phase_end
                phase_begin sip_drain
                log "SIPp: sem novas chamadas; aguardando as ativas terminarem (ate $((OPT_HOLD + 60)) s)"
            fi
        else
            guard_check 0
            # O SIPp 3.6.1 as vezes trava na saida suave mesmo sem chamadas ativas
            if sip_all_done; then
                log "SIPp: todas as chamadas encerradas; finalizando o processo"
                kill -TERM "${SIPP_PID}" 2>/dev/null || true
            elif (( $(now) - soft_at > OPT_HOLD + 60 )); then
                warn "SIPp nao encerrou no prazo; enviando SIGTERM"
                kill -TERM "${SIPP_PID}" 2>/dev/null || true
            fi
        fi
    done
    wait "${SIPP_PID}" 2>/dev/null || rc=$?
    SIPP_PID=""
    stop_uas
    phase_end
    log "SIPp encerrado (rc=${rc}; 0 = sem falhas, 1 = houve chamadas com falha)"
    if [[ -n $(sip_real_errors "${dir}/sipp.stderr") ]]; then
        warn "SIPp stderr: $(sip_real_errors "${dir}/sipp.stderr" | head -c 300 | tr '\n' ' ')"
    fi
    if uas_enabled && [[ -n $(sip_real_errors "${RUN_DIR}/uas/sipp.stderr") ]]; then
        warn "atendedor stderr: $(sip_real_errors "${RUN_DIR}/uas/sipp.stderr" | head -c 300 | tr '\n' ' ')"
    fi
}

# Executa um comando de carga em background vigiando os limites.
run_guarded() {
    local out=$1; shift
    "$@" > "${out}" 2>&1 &
    LOAD_PID=$!
    while kill -0 "${LOAD_PID}" 2>/dev/null; do
        sleep "${CFG[SAMPLE_INTERVAL]}" || true
        guard_check 0
        if [[ -n ${ABORT_REASON} ]]; then
            kill -TERM "${LOAD_PID}" 2>/dev/null || true
        fi
    done
    wait "${LOAD_PID}" 2>/dev/null || true
    LOAD_PID=""
}

run_mysql_phase() {
    local dir="${RUN_DIR}/mysql" pass db=${CFG[MYSQL_BENCH_DB]}
    local -a common extra
    mkdir -p "${dir}"
    pass=$(< "${CFG[MYSQL_BENCH_PASSWORD_FILE]}")
    pass=${pass%$'\n'}
    read -ra extra <<< "${CFG[MYSQL_BENCH_EXTRA_ARGS]}"
    common=(--db-driver=mysql --mysql-host="${CFG[MYSQL_BENCH_HOST]}" --mysql-port="${CFG[MYSQL_BENCH_PORT]}"
        --mysql-user="${CFG[MYSQL_BENCH_USER]}" --mysql-password="${pass}" --mysql-db="${db}"
        --tables="${CFG[MYSQL_BENCH_TABLES]}" --table-size="${CFG[MYSQL_BENCH_TABLE_SIZE]}" "${extra[@]}")

    phase_begin mysql_prepare
    if ! MYSQL_PWD="${pass}" mysql -h "${CFG[MYSQL_BENCH_HOST]}" -P "${CFG[MYSQL_BENCH_PORT]}" \
            -u "${CFG[MYSQL_BENCH_USER]}" -e "CREATE DATABASE IF NOT EXISTS \`${db}\`" > "${dir}/create.txt" 2>&1; then
        phase_end
        warn "nao foi possivel criar o schema ${db}: $(head -c 300 "${dir}/create.txt")"
        return 0
    fi
    run_guarded "${dir}/prepare.txt" sysbench oltp_read_write "${common[@]}" --threads="${CFG[MYSQL_BENCH_THREADS]}" prepare
    phase_end
    if [[ -z ${ABORT_REASON} ]]; then
        phase_begin mysql
        run_guarded "${dir}/run.txt" sysbench oltp_read_write "${common[@]}" \
            --threads="${CFG[MYSQL_BENCH_THREADS]}" --time="${OPT_MYSQL_DURATION}" \
            --report-interval="${CFG[SAMPLE_INTERVAL]}" --percentile=95 run
        phase_end
    fi
    # cleanup sempre, mesmo apos abort: remove as tabelas sbtest* do schema isolado
    phase_begin mysql_cleanup
    sysbench oltp_read_write "${common[@]}" cleanup > "${dir}/cleanup.txt" 2>&1 \
        || warn "sysbench cleanup falhou; remova as tabelas sbtest* do schema ${db} manualmente"
    phase_end
}

# URL com porta explicita para o wrk: sem /etc/services (Debian minimo, pacote
# netbase ausente) ele nao traduz "https" para 443 e falha sem gerar resultado.
wrk_url() {
    local url=$1 port=443
    if [[ ${url} =~ ^(https?)://([^/:]+)(/.*)?$ ]]; then
        [[ ${BASH_REMATCH[1]} == http ]] && port=80
        printf '%s://%s:%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${port}" "${BASH_REMATCH[3]}"
    else
        printf '%s' "${url}"
    fi
}

web_session_cookie() {
    local url=$1 jar="${RUN_DIR}/web/cookies.txt" code
    local -a k=()
    [[ ${CFG[WEB_TLS_INSECURE]} == 1 ]] && k=(-k)
    code=$(curl -s "${k[@]}" -m 15 -A "${UA}" -c "${jar}" -o /dev/null -w '%{http_code}' "${url}" || true)
    [[ ${code} =~ ^[23] ]] || { warn "GET ${url} retornou HTTP ${code:-erro}"; return 1; }
    awk -v n="${CFG[WEB_SESSION_COOKIE]}" 'NF >= 7 && $6 == n { v = $7 } END { if (v != "") print n "=" v }' "${jar}"
}

run_web_phase() {
    local dir="${RUN_DIR}/web" name path url cookie code
    local -a hdr targets k=()
    mkdir -p "${dir}"
    [[ ${CFG[WEB_TLS_INSECURE]} == 1 ]] && k=(-k)
    targets=("static|${CFG[WEB_STATIC_PATH]}" "php|${CFG[WEB_PHP_PATH]}")
    [[ -n ${CFG[WEB_EXTRA_PATH]} ]] && targets+=("extra|${CFG[WEB_EXTRA_PATH]}")
    for name in "${targets[@]}"; do
        [[ -z ${ABORT_REASON} ]] || break
        path=${name#*|}
        name=${name%%|*}
        url="${CFG[WEB_BASE_URL]%/}${path}"
        hdr=(-H "User-Agent: ${UA}")
        if [[ ${name} != static && ${CFG[WEB_REUSE_SESSION]} == 1 ]]; then
            # Uma sessao para todo o teste: sem isso cada request cria uma linha em ci_sessions.
            if cookie=$(web_session_cookie "${url}") && [[ -n ${cookie} ]]; then
                hdr+=(-H "Cookie: ${cookie}")
            else
                warn "web ${name}: sem cookie ${CFG[WEB_SESSION_COOKIE]}; alvo ignorado para nao criar sessoes no banco"
                continue
            fi
        else
            code=$(curl -s "${k[@]}" -m 15 -A "${UA}" -o /dev/null -w '%{http_code}' "${url}" || true)
            if [[ ! ${code} =~ ^[23] ]]; then
                warn "web ${name}: ${url} retornou HTTP ${code:-erro}; alvo ignorado"
                continue
            fi
        fi
        printf '%s\n' "${url}" > "${dir}/${name}.url"
        phase_begin "web_${name}"
        run_guarded "${dir}/${name}.txt" wrk -t "${OPT_WEB_THREADS}" -c "${OPT_WEB_CONNS}" \
            -d "${OPT_WEB_DURATION}s" --latency --timeout 10s "${hdr[@]}" "$(wrk_url "${url}")"
        phase_end
        if ! grep -q 'Requests/sec' "${dir}/${name}.txt"; then
            warn "web ${name}: wrk sem resultado: $(head -c 200 "${dir}/${name}.txt" | tr '\n' ' ')"
        fi
        wait_seconds 10
    done
    # o cookie da sessao anonima nao vai para o pacote de resultados
    rm -f "${dir}/cookies.txt"
}

# --------------------------------------------------------------- relatorio
fmt_rt_ms() {
    # "HH:MM:SS:uuuuuu" do SIPp -> milissegundos
    awk -F: '{ if (NF == 4) printf "%.1f", ($1 * 3600 + $2 * 60 + $3) * 1000 + $4 / 1000; else printf "-" }' <<< "$1"
}

# Linhas do errors.log/stderr do SIPp que nao sao falha:
#   "Resolving remote host"            resolucao do destino
#   "There were more errors"               aviso do SIPp apontando para o errors.log
#   "receive timeout ... jumping to label"  fim do hold: o cenario deixa de esperar o
#                                           BYE do FS e envia o BYE local (caminho normal)
sip_real_errors() {
    grep -v -e 'Resolving remote host' -e 'jumping to label' -e 'There were more errors' "$1" 2>/dev/null || true
}

report_sip() {
    local dir=$1 stats="$1/sip/stats.csv"
    [[ -s ${stats} ]] || { printf '  (sem dados do SIPp)\n'; return 0; }
    local vals rt1 rt2 cl
    vals=$(awk -F';' 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
        { l = $0; split($0, v, ";")
          cc = v[c["CurrentCall"]] + 0; if (cc > mc) mc = cc
          r = v[c["CallRate(P)"]] + 0; if (r > mr) mr = r }
        END {
            split(l, v, ";")
            printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
                v[c["TotalCallCreated"]], v[c["SuccessfulCall(C)"]], v[c["FailedCall(C)"]],
                v[c["FailedMaxUDPRetrans(C)"]], v[c["FailedUnexpectedMessage(C)"]],
                v[c["FailedCallRejected(C)"]], mc, mr, v[c["CallRate(C)"]],
                v[c["ResponseTime1(C)"]], v[c["ResponseTime2(C)"]], v[c["CallLength(C)"]]
        }' "${stats}")
    local total ok fail retr unexp rej mc mr cr
    IFS='|' read -r total ok fail retr unexp rej mc mr cr rt1 rt2 cl <<< "${vals}"
    local pct="-"
    if (( ${ok:-0} + ${fail:-0} > 0 )); then
        pct=$(awk -v f="${fail}" -v o="${ok}" 'BEGIN { printf "%.2f", f * 100 / (f + o) }')
    fi
    printf '  %-36s %s\n' "Chamadas criadas" "${total}"
    printf '  %-36s %s\n' "Concluidas com sucesso" "${ok}"
    printf '  %-36s %s (%s%%)\n' "Falhas" "${fail}" "${pct}"
    printf '  %-36s %s\n' "  timeout de retransmissao UDP" "${retr}"
    printf '  %-36s %s\n' "  resposta inesperada (4xx/5xx)" "${unexp}"
    printf '  %-36s %s\n' "  rejeitadas" "${rej}"
    printf '  %-36s %s\n' "Encerradas pelo FS (BYE remoto)" "$(grep -c REMOTE_BYE "${dir}/sip/actions.log" 2>/dev/null || true)"
    # LOCAL_BYE vem de uma acao <log> do cenario: o errors.log do SIPp nao registra
    # todos os "receive timeout ... jumping to label" (resume com "There were more errors")
    printf '  %-36s %s\n' "Encerradas pela VM (fim do hold)" "$(grep -c LOCAL_BYE "${dir}/sip/actions.log" 2>/dev/null || true)"
    printf '  %-36s %s\n' "Pico de chamadas simultaneas" "${mc}"
    printf '  %-36s %s\n' "Pico de CPS (por periodo)" "${mr}"
    printf '  %-36s %s\n' "CPS medio da fase" "${cr}"
    printf '  %-36s %s ms\n' "INVITE -> 100 (media)" "$(fmt_rt_ms "${rt1}")"
    printf '  %-36s %s ms\n' "INVITE -> 200 (media)" "$(fmt_rt_ms "${rt2}")"
    printf '  %-36s %s ms\n' "Duracao media da chamada" "$(fmt_rt_ms "${cl}")"
    local reasons
    reasons=$(sip_real_errors "${dir}/sip/errors.log" | {
            grep -o "received 'SIP/2.0 [0-9][0-9][0-9][^']*\|retransmission timeout\|receive timeout" \
                | sed -e "s/received 'SIP\/2.0 /resposta /" \
                      -e 's/^receive timeout$/timeout de recepcao (SIP_RECV_TIMEOUT_MS)/' \
                      -e 's/^retransmission timeout$/timeout de retransmissao UDP/' || true
        } | sort | uniq -c | sort -rn | head -15)
    if [[ -n ${reasons} ]]; then
        printf '\n  Falhas por motivo (errors.log):\n'
        printf '%s\n' "${reasons}" | sed 's/^/  /'
    fi
}

report_hosts() {
    local dir=$1 id role addr name file
    while IFS=$'\t' read -r id role addr name; do
        file="${dir}/metrics/${id}.csv"
        printf '\n-- %s (%s, %s%s)\n' "${id}" "${role}" "${addr}" "${name:+, ${name}}"
        if [[ ! -s ${file} ]] || (( $(grep -c '' "${file}") < 2 )); then
            printf '  (sem amostras; veja metrics/%s.err)\n' "${id}"
            continue
        fi
        awk -F, -v phases="${dir}/phases.tsv" '
            BEGIN {
                while ((getline l < phases) > 0) {
                    split(l, p, "\t")
                    if (p[1] ~ /^(mysql_prepare|mysql_cleanup)$/) continue
                    np++; pn[np] = p[1]; ps[np] = p[2]; pe[np] = p[3]
                }
                minset["disk_free_pct"] = 1; minset["mem_avail_mb"] = 1; minset["fs_idle_cpu"] = 1
            }
            NR == 1 { for (i = 1; i <= NF; i++) h[i] = $i; nf = NF; next }
            NF != nf { next }
            {
                ph = 0
                for (k = 1; k <= np; k++) if ($1 > ps[k] && $1 <= pe[k]) { ph = k; break }
                if (!ph) next
                seen[ph] = 1
                for (i = 2; i <= nf; i++) {
                    if (h[i] == "cpu_max_core" || $i == "" || $i !~ /^-?[0-9.]+$/) continue
                    key = ph SUBSEP i; v = $i + 0
                    if (!(key in cnt)) { mn[key] = v; mx[key] = v; first[key] = v }
                    cnt[key]++; sum[key] += v; lst[key] = v
                    if (v > mx[key]) mx[key] = v
                    if (v < mn[key]) mn[key] = v
                    has[i] = 1
                }
            }
            function num(x) { return (x == int(x)) ? sprintf("%d", x) : sprintf("%.1f", x) }
            END {
                printf "  %-26s", "metrica (media/pico)"
                for (k = 1; k <= np; k++) if (seen[k]) printf " %15s", pn[k]
                printf "\n"
                for (i = 2; i <= nf; i++) {
                    if (!has[i]) continue
                    printf "  %-26s", h[i]
                    for (k = 1; k <= np; k++) {
                        if (!seen[k]) continue
                        key = k SUBSEP i
                        if (!(key in cnt)) { printf " %15s", "-"; continue }
                        if (h[i] ~ /_total$/) cell = "+" num(lst[key] - first[key])
                        else if (h[i] in minset) cell = num(sum[key] / cnt[key]) "/" num(mn[key]) "m"
                        else cell = num(sum[key] / cnt[key]) "/" num(mx[key])
                        printf " %15s", cell
                    }
                    printf "\n"
                }
            }' "${file}"
    done < "${dir}/hosts.tsv"
}

report_wrk() {
    local f=$1
    if ! grep -q 'Requests/sec' "${f}"; then
        printf '  sem resultado do wrk: %s\n' "$(head -n 1 "${f}")"
        return 0
    fi
    awk '
        /Latency  / && !lat { printf "  latencia media/desvio/max: %s / %s / %s\n", $2, $3, $4; lat = 1 }
        /^ +50%/ { p50 = $2 } /^ +90%/ { p90 = $2 } /^ +99%/ { p99 = $2 }
        /requests in/ { printf "  total: %s\n", $0 }
        /Requests\/sec/ { printf "  req/s: %s\n", $2 }
        /Transfer\/sec/ { printf "  transferencia/s: %s\n", $2 }
        /Non-2xx/ { printf "  respostas nao 2xx/3xx: %s\n", $NF }
        /Socket errors/ { printf "  erros de socket: %s\n", $0 }
        END { if (p50 != "") printf "  latencia p50/p90/p99: %s / %s / %s\n", p50, p90, p99 }' "${f}"
}

report_sysbench() {
    local f=$1
    if grep -qE '^ +transactions:' "${f}"; then
        grep -E '^ +(transactions|queries|ignored errors|reconnects):|^ +(min|avg|max|95th percentile):' "${f}" \
            | sed 's/^ */  /'
    elif grep -q '^\[ ' "${f}"; then
        printf '  interrompido antes do resumo; ultimos intervalos:\n'
        grep '^\[ ' "${f}" | tail -n 3 | sed 's/^/    /'
    else
        printf '  (sem resultado)\n'
    fi
}

# Ultima linha do stats.csv do SIPp: valores das colunas pedidas, separados por "|"
sipp_last() {
    local stats=$1; shift
    awk -F';' -v want="$*" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } { l = $0 }
        END {
            if (l == "") exit 1
            split(l, v, ";"); n = split(want, w, " ")
            for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "|" : ""), (w[i] in c ? v[c[w[i]]] : "")
            printf "\n"
        }' "${stats}"
}

report_uas() {
    local dir=$1 stats="$1/uas/stats.csv" total ok fail unexp tmo cl mc sent lost pct="-"
    [[ -s ${stats} ]] || { printf '  (sem dados do atendedor)\n'; return 0; }
    IFS='|' read -r total ok fail unexp tmo cl < <(sipp_last "${stats}" TotalCallCreated \
        "SuccessfulCall(C)" "FailedCall(C)" "FailedUnexpectedMessage(C)" "FailedTimeoutOnRecv(C)" "CallLength(C)")
    mc=$(awk -F';' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "CurrentCall") k = i; next }
        k && $k + 0 > m { m = $k + 0 } END { print m + 0 }' "${stats}")
    if (( ${ok:-0} + ${fail:-0} > 0 )); then
        pct=$(awk -v f="${fail}" -v o="${ok}" 'BEGIN { printf "%.2f", f * 100 / (f + o) }')
    fi
    printf '  %-36s %s\n' "Chamadas recebidas do FS" "${total}"
    printf '  %-36s %s\n' "Atendidas e encerradas (BYE)" "${ok}"
    printf '  %-36s %s (%s%%)\n' "Falhas" "${fail}" "${pct}"
    printf '  %-36s %s\n' "  mensagem inesperada" "${unexp}"
    printf '  %-36s %s\n' "  sem BYE no prazo (hold + 120 s)" "${tmo}"
    printf '  %-36s %s\n' "Pico de chamadas simultaneas" "${mc}"
    printf '  %-36s %s ms\n' "Duracao media da chamada" "$(fmt_rt_ms "${cl}")"
    if [[ -s ${dir}/sip/stats.csv ]] && sent=$(sipp_last "${dir}/sip/stats.csv" TotalCallCreated); then
        lost=$(( ${sent:-0} - ${total:-0} ))
        printf '  %-36s %s\n' "Originadas que nao chegaram aqui" "$((lost > 0 ? lost : 0))"
        printf '  (recusadas pelo OpenSIPS/FS antes do bridge: confira DIDs DIRECT-IP e o errors.log do originador)\n'
    fi
    local reasons
    reasons=$(sip_real_errors "${dir}/uas/errors.log" | {
            grep -o "Aborting call on unexpected message[^']*\|receive timeout\|Dead call [^(]*" || true
        } | sort | uniq -c | sort -rn | head -10)
    if [[ -n ${reasons} ]]; then
        printf '\n  Falhas por motivo (uas/errors.log):\n'
        printf '%s\n' "${reasons}" | sed 's/^/  /'
    fi
}

generate_report() {
    local dir=$1 out="$1/report.txt" k f
    [[ -d ${dir} ]] || die "${E_USAGE}" "diretorio de resultado inexistente: ${dir}"
    [[ -f ${dir}/phases.tsv ]] || touch "${dir}/phases.tsv"
    {
        printf 'FluxSBC - Teste de carga (WEB-1437)\n'
        printf '===================================\n\n'
        if [[ -f ${dir}/run.env ]]; then
            while IFS='=' read -r k f; do
                printf '  %-22s %s\n' "${k}" "${f}"
            done < "${dir}/run.env"
        fi

        printf '\n== Linha do tempo\n'
        while IFS=$'\t' read -r k f end; do
            printf '  %-14s %(%F %T)T -> %(%T)T  (%d s)\n' "${k}" "${f}" "${end}" $((end - f))
        done < "${dir}/phases.tsv"

        printf '\n== Limites de seguranca\n'
        if [[ -f ${dir}/abort.txt ]]; then
            printf '  EXECUCAO INTERROMPIDA: %s\n' "$(cat "${dir}/abort.txt")"
        else
            printf '  nenhum limite atingido\n'
        fi
        if [[ -s ${dir}/guard.log ]]; then
            printf '  ocorrencias registradas (ultimas 15; completo em guard.log):\n'
            tail -n 15 "${dir}/guard.log" | while IFS=$'\t' read -r k f end n; do
                printf '    %(%T)T  %-12s %-36s %s\n' "${k}" "${f}" "${end}" "${n}"
            done
        fi

        if [[ -d ${dir}/sip ]]; then
            printf '\n== SIP (SIPp -> %s)\n' "$(awk -F= '$1 == "sip_destino" { print $2 }' "${dir}/run.env" 2>/dev/null)"
            report_sip "${dir}"
        fi

        if [[ -d ${dir}/uas ]]; then
            printf '\n== Atendedor (SIPp UAS em %s)\n' "$(awk -F= '$1 == "atendedor" { print $2 }' "${dir}/run.env" 2>/dev/null)"
            report_uas "${dir}"
        fi

        if [[ -d ${dir}/mysql ]]; then
            printf '\n== MySQL (sysbench oltp_read_write, schema isolado)\n'
            if [[ -s ${dir}/mysql/run.txt ]]; then report_sysbench "${dir}/mysql/run.txt"; else printf '  (nao executado)\n'; fi
        fi

        if [[ -d ${dir}/web ]]; then
            printf '\n== Web (wrk)\n'
            for f in "${dir}"/web/*.txt; do
                [[ -e ${f} && ${f##*/} != cookies.txt ]] || continue
                k=${f##*/}
                printf '  -- %s: %s\n' "${k%.txt}" "$(cat "${f%.txt}.url" 2>/dev/null || true)"
                report_wrk "${f}"
            done
        fi

        if [[ -f ${dir}/clock.tsv ]]; then
            printf '\n== Diferenca de relogio (servidor - VM de teste, s)\n'
            sed 's/^/  /' "${dir}/clock.tsv"
        fi

        printf '\n== Servidores por fase\n'
        printf '  celulas: media/pico; "m" = minimo (disco livre, memoria disponivel); "+" = variacao do contador\n'
        printf '  *_cpu_pct de processo: 100 = 1 nucleo. cpu_pct: percentual do servidor inteiro.\n'
        [[ -f ${dir}/hosts.tsv ]] && report_hosts "${dir}"
        printf '\nArquivos brutos: %s\n' "${dir}"
    } > "${out}"
    REPORT_DONE=1
    log "relatorio: ${out}"
}

# --------------------------------------------------------------- chaves SSH
# keys create|trust|deploy|test|revoke|setup
# A chave e instalada restrita a VM de teste (from= + no-pty/no-*-forwarding):
# o script so executa comandos sem terminal, entao nada disso o afeta.
KEY_VIA="" KEY_FROM="" KEY_PASSPHRASE=0 KEY_WRITE_CONFIG=0 KEY_YES=0
KEY_ADDRS=()

parse_keys_opts() {
    while (($# > 0)); do
        case "$1" in
            --key)          CFG[SSH_KEY]=${2:-}; shift 2 ;;
            --type)         CFG[SSH_KEY_TYPE]=${2:-}; shift 2 ;;
            --comment)      CFG[SSH_KEY_COMMENT]=${2:-}; shift 2 ;;
            --known-hosts)  CFG[SSH_KNOWN_HOSTS]=${2:-}; shift 2 ;;
            --from)         KEY_FROM=${2:-}; shift 2 ;;
            --via)          KEY_VIA=${2:-}; shift 2 ;;
            --passphrase)   KEY_PASSPHRASE=1; shift ;;
            --write-config) KEY_WRITE_CONFIG=1; shift ;;
            -y|--yes)       KEY_YES=1; shift ;;
            *) usage >&2; die "${E_USAGE}" "opcao invalida para keys: $1" ;;
        esac
    done
    [[ -n ${CFG[SSH_KEY]} ]] || die "${E_CONFIG}" "defina SSH_KEY na configuracao ou use --key CAMINHO"
    [[ ${CFG[SSH_KEY]} == /* ]] || die "${E_CONFIG}" "SSH_KEY deve ser caminho absoluto: ${CFG[SSH_KEY]}"
    [[ ${CFG[SSH_KEY_TYPE]} == ed25519 || ${CFG[SSH_KEY_TYPE]} == rsa ]] || die "${E_USAGE}" "--type deve ser ed25519 ou rsa"
    [[ -z ${CFG[SSH_KNOWN_HOSTS]} || ${CFG[SSH_KNOWN_HOSTS]} == /* ]] || die "${E_USAGE}" "--known-hosts deve ser caminho absoluto"
    [[ -z ${KEY_VIA} || ${KEY_VIA} =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || die "${E_USAGE}" "--via: usuario invalido"
    [[ ${CFG[SSH_USER]} =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || die "${E_CONFIG}" "SSH_USER invalido: ${CFG[SSH_USER]}"
    [[ -n ${KEY_FROM} ]] || KEY_FROM=${CFG[SSH_KEY_FROM]}
    [[ -z ${KEY_FROM} || ${KEY_FROM} =~ ^[0-9A-Fa-f.:/,*?]+$ ]] || die "${E_USAGE}" "--from invalido (IPs/CIDR separados por virgula)"
}

# Enderecos unicos (o mesmo IP pode aparecer em mais de um papel).
key_hosts() {
    local id addr seen=" "
    KEY_ADDRS=()
    for id in "${HOST_IDS[@]}"; do
        addr=${HOST_ADDR[${id}]}
        [[ ${seen} == *" ${addr} "* ]] && continue
        seen+="${addr} "
        KEY_ADDRS+=("${addr}")
    done
}

known_hosts_file() {
    printf '%s' "${CFG[SSH_KNOWN_HOSTS]:-${HOME}/.ssh/known_hosts}"
}

known_hosts_name() {
    if [[ ${CFG[SSH_PORT]} == 22 ]]; then printf '%s' "$1"; else printf '[%s]:%s' "$1" "${CFG[SSH_PORT]}"; fi
}

confirm() {
    local prompt=$1 ans
    ((KEY_YES)) && return 0
    [[ -t 0 ]] || die "${E_USAGE}" "confirmacao necessaria e sem terminal; use -y"
    read -r -p "${prompt} [s/N] " ans
    [[ ${ans} == s || ${ans} == S ]]
}

# Grava CHAVE=valor no arquivo de configuracao (substitui ou acrescenta; backup .bak).
set_config_value() {
    local file=$1 key=$2 val=$3 tmp
    [[ -w ${file} ]] || { warn "${file} sem permissao de escrita; ajuste ${key} manualmente"; return 0; }
    [[ -f ${file}.bak ]] || cp -p "${file}" "${file}.bak"
    tmp=$(mktemp "${file}.XXXXXX")
    awk -v k="${key}" -v v="${val}" '
        index($0, k "=") == 1 { print k "=" v; done = 1; next } { print }
        END { if (!done) print k "=" v }' "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
    log "${file}: ${key}=${val}"
}

keys_create() {
    local key=${CFG[SSH_KEY]} comment
    local -a kopts pass=(-N "")
    if [[ -e ${key} ]]; then
        log "chave ja existe: ${key}"
        ssh-keygen -l -f "${key}.pub" 2>/dev/null || warn "${key}.pub ausente: gere de novo com ssh-keygen -y -f ${key}"
    else
        comment=${CFG[SSH_KEY_COMMENT]:-flux-loadtest@$(uname -n)-$(date +%Y%m%d)}
        [[ ${comment} =~ ^[A-Za-z0-9@._:-]{1,64}$ ]] || die "${E_USAGE}" "comentario da chave invalido: ${comment}"
        case "${CFG[SSH_KEY_TYPE]}" in
            ed25519) kopts=(-t ed25519 -a 100) ;;
            rsa)     kopts=(-t rsa -b 4096 -a 100) ;;
        esac
        # Sem passphrase por padrao: o teste roda sem interacao (BatchMode).
        # Com --passphrase, carregue a chave no ssh-agent antes do run.
        ((KEY_PASSPHRASE)) && pass=()
        install -d -m 0700 "$(dirname "${key}")"
        ssh-keygen -q "${kopts[@]}" "${pass[@]}" -C "${comment}" -f "${key}" \
            || die "${E_CONFIG}" "ssh-keygen falhou"
        chmod 0600 "${key}"
        chmod 0644 "${key}.pub"
        log "chave criada: ${key} (${CFG[SSH_KEY_TYPE]})"
        ssh-keygen -l -f "${key}.pub"
    fi
    if ((KEY_WRITE_CONFIG)); then
        set_config_value "${CONFIG_FILE}" SSH_KEY "${key}"
    fi
}

keys_trust() {
    local known addr name scan
    local -a new=()
    known=$(known_hosts_file)
    install -d -m 0700 "$(dirname "${known}")"
    [[ -e ${known} ]] || install -m 0600 /dev/null "${known}"
    printf '\n== Chaves de host (%s)\n' "${known}"
    for addr in "${KEY_ADDRS[@]}"; do
        name=$(known_hosts_name "${addr}")
        if ssh-keygen -F "${name}" -f "${known}" >/dev/null 2>&1; then
            printf '  %-22s ja confiavel\n' "${name}"
            continue
        fi
        scan=$(ssh-keyscan -T 5 -p "${CFG[SSH_PORT]}" -t ed25519,ecdsa,rsa "${addr}" 2>/dev/null || true)
        if [[ -z ${scan} ]]; then
            warn "${addr}: ssh-keyscan sem resposta na porta ${CFG[SSH_PORT]}"
            continue
        fi
        printf '  %-22s\n' "${name}"
        ssh-keygen -l -f - <<< "${scan}" | sed 's/^/      /'
        new+=("${scan}")
    done
    ((${#new[@]} > 0)) || { log "nenhuma chave de host nova"; return 0; }
    printf '\n  Confira as impressoes digitais com a infraestrutura, no servidor:\n'
    printf '    ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub\n\n'
    confirm "Gravar ${#new[@]} servidor(es) em ${known}?" || die "${E_ABORT}" "cancelado: chaves de host nao gravadas"
    printf '%s\n' "${new[@]}" >> "${known}"
    log "${#new[@]} servidor(es) gravado(s) em ${known}"
    if ((KEY_WRITE_CONFIG)) && [[ -n ${CFG[SSH_KNOWN_HOSTS]} ]]; then
        set_config_value "${CONFIG_FILE}" SSH_KNOWN_HOSTS "${CFG[SSH_KNOWN_HOSTS]}"
    fi
}

# IP de origem usado para chegar ao servidor (vira o from= do authorized_keys).
key_from_for() {
    if [[ -n ${KEY_FROM} ]]; then
        printf '%s' "${KEY_FROM}"
        return 0
    fi
    ip -o route get "$1" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

read_pubkey() {
    local pub=${CFG[SSH_KEY]}.pub
    [[ -r ${pub} ]] || die "${E_CONFIG}" "chave publica ausente: ${pub} (rode: $0 keys create)"
    PUBKEY=$(head -n 1 "${pub}")
    [[ ${PUBKEY} =~ ^(ssh-ed25519|ssh-rsa)\ ([A-Za-z0-9+/=]+)(\ [A-Za-z0-9@._:-]+)?$ ]] \
        || die "${E_CONFIG}" "formato inesperado em ${pub}"
    PUBKEY_DATA=${BASH_REMATCH[2]}
}

# Executa um script sh no servidor com acesso interativo (senha ou admin + sudo).
# O script vai em base64 no comando: o terminal fica livre para os prompts de senha.
remote_bootstrap() {
    local addr=$1 script=$2 b64 login cmd
    local -a opts base
    read -ra opts <<< "${CFG[SSH_OPTS]}"
    # Primeira ocorrencia de cada -o vale: BatchMode=no precisa vir antes de SSH_OPTS.
    base=(ssh -p "${CFG[SSH_PORT]}" -o BatchMode=no -o ConnectTimeout=10 -o LogLevel=ERROR
        -o "PreferredAuthentications=publickey,keyboard-interactive,password"
        -o NumberOfPasswordPrompts=2 "${opts[@]}")
    [[ -n ${CFG[SSH_KNOWN_HOSTS]} ]] && base+=(-o "UserKnownHostsFile=${CFG[SSH_KNOWN_HOSTS]}")
    # Sem --via, a propria chave (se ja instalada) evita pedir senha de novo.
    if [[ -z ${KEY_VIA} && -r ${CFG[SSH_KEY]} ]]; then
        base+=(-i "${CFG[SSH_KEY]}")
    fi
    b64=$(printf '%s\n' "${script}" | base64 | tr -d '\n')
    if [[ -n ${KEY_VIA} && ${KEY_VIA} != root ]]; then
        login=${KEY_VIA}
        cmd="echo ${b64} | base64 -d | sudo -p '[sudo] password for %u@%H: ' sh"
        # -tt: o sudo precisa de terminal remoto para o prompt de senha
        "${base[@]}" -tt "${login}@${addr}" "${cmd}"
    else
        login=${KEY_VIA:-${CFG[SSH_USER]}}
        cmd="echo ${b64} | base64 -d | sh"
        "${base[@]}" "${login}@${addr}" "${cmd}"
    fi
}

# Script sh (POSIX) que instala/atualiza a linha no authorized_keys de um usuario.
deploy_script() {
    local user=$1 data=$2 line=$3
    cat <<SH
set -eu
u='${user}'
h=\$(getent passwd "\$u" | cut -d: -f6)
[ -n "\$h" ] || { echo "ERRO: usuario \$u nao existe neste servidor" >&2; exit 3; }
d="\$h/.ssh"; f="\$d/authorized_keys"
umask 077
mkdir -p "\$d"; touch "\$f"
if grep -qF '${data}' "\$f"; then
    if grep -qxF '${line}' "\$f"; then
        echo "ja instalada"
    else
        t=\$(mktemp "\$d/.ak.XXXXXX")
        awk -v k='${data}' -v l='${line}' 'index(\$0, k) { print l; next } { print }' "\$f" > "\$t"
        cat "\$t" > "\$f"; rm -f "\$t"
        echo "atualizada (restricoes)"
    fi
else
    printf '%s\n' '${line}' >> "\$f"
    echo "instalada"
fi
chmod 700 "\$d"; chmod 600 "\$f"
if [ "\$(id -u)" -eq 0 ]; then chown "\$u": "\$d" "\$f"; fi
SH
}

keys_deploy() {
    local addr from opts line rc fails=0
    read_pubkey
    printf '\n== Instalando a chave para %s\n' "${CFG[SSH_USER]}"
    [[ -n ${KEY_VIA} ]] && printf '  acesso via %s%s\n' "${KEY_VIA}" "$([[ ${KEY_VIA} != root ]] && printf ' + sudo')"
    for addr in "${KEY_ADDRS[@]}"; do
        from=$(key_from_for "${addr}")
        [[ -n ${from} ]] || { warn "${addr}: IP de origem nao detectado; use --from"; fails=$((fails + 1)); continue; }
        opts="from=\"${from}\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc"
        line="${opts} ${PUBKEY}"
        printf -- '-- %s (from=%s)\n' "${addr}" "${from}"
        rc=0
        # Saida direta no terminal: os prompts de senha (ssh e sudo) precisam aparecer.
        remote_bootstrap "${addr}" "$(deploy_script "${CFG[SSH_USER]}" "${PUBKEY_DATA}" "${line}")" || rc=$?
        ((rc == 0)) || { warn "${addr}: falha (rc=${rc})"; fails=$((fails + 1)); }
    done
    ((fails == 0)) || die "${E_REMOTE}" "${fails} servidor(es) sem a chave instalada"
}

keys_test() {
    local addr out fails=0
    build_ssh 1
    printf '\n== Teste de acesso por chave (%s)\n' "${CFG[SSH_USER]}"
    for addr in "${KEY_ADDRS[@]}"; do
        if out=$(timeout 20 "${SSH_CMD[@]}" -n "${CFG[SSH_USER]}@${addr}" \
                'printf "%s " "$(id -un)"; if sudo -n true 2>/dev/null; then echo "sudo -n: total"; elif sudo -n -l >/dev/null 2>&1; then echo "sudo -n: restrito ($(sudo -n -l 2>/dev/null | sed -n "/may run/,\$p" | grep -o "/[^ ,]*" | tr "\n" " "))"; else echo "sudo -n: indisponivel"; fi' 2>&1); then
            printf '  %-16s ok  %s\n' "${addr}" "${out}"
        else
            printf '  %-16s FALHA  %s\n' "${addr}" "$(printf '%s' "${out}" | tail -n 1)"
            fails=$((fails + 1))
        fi
    done
    printf '  sudo -n so e necessario se FS_CLI_CMD/OPENSIPS_MI_CMD usam sudo\n'
    ((fails == 0)) || die "${E_REMOTE}" "${fails} servidor(es) sem acesso por chave"
}

keys_revoke() {
    local addr script rc fails=0
    read_pubkey
    printf '\n== Remover a chave %s de %s em %s servidor(es)\n' "${PUBKEY_DATA:0:16}..." "${CFG[SSH_USER]}" "${#KEY_ADDRS[@]}"
    confirm "Remover a chave do authorized_keys?" || die "${E_ABORT}" "cancelado"
    script=$(cat <<SH
set -eu
h=\$(getent passwd '${CFG[SSH_USER]}' | cut -d: -f6)
f="\$h/.ssh/authorized_keys"
[ -f "\$f" ] || { echo "sem authorized_keys"; exit 0; }
n=\$(grep -cF '${PUBKEY_DATA}' "\$f" || true)
if [ "\$n" -gt 0 ]; then
    t=\$(mktemp "\$h/.ssh/.ak.XXXXXX")
    grep -vF '${PUBKEY_DATA}' "\$f" > "\$t" || true
    cat "\$t" > "\$f"; rm -f "\$t"
    echo "removida (\$n linha)"
else
    echo "nao encontrada"
fi
SH
)
    build_ssh 0
    for addr in "${KEY_ADDRS[@]}"; do
        printf -- '-- %s\n' "${addr}"
        rc=0
        if [[ -n ${KEY_VIA} ]]; then
            remote_bootstrap "${addr}" "${script}" || rc=$?
        else
            # a propria chave autentica a sessao que a remove
            printf '%s\n' "${script}" | timeout 30 "${SSH_CMD[@]}" -T "${CFG[SSH_USER]}@${addr}" sh 2>&1 \
                | sed 's/^/   /' || rc=$?
        fi
        ((rc == 0)) || { warn "${addr}: falha (rc=${rc})"; fails=$((fails + 1)); }
    done
    ((fails == 0)) || die "${E_REMOTE}" "${fails} servidor(es) com falha na remocao"
}

cmd_keys() {
    local sub=${1:-}
    (($# > 0)) && shift
    case "${sub}" in
        create|trust|deploy|test|revoke|setup) ;;
        *) usage >&2; die "${E_USAGE}" "uso: $0 keys create|trust|deploy|test|revoke|setup [opcoes]" ;;
    esac
    parse_keys_opts "$@"
    check_local_deps ssh ssh-keygen ssh-keyscan base64 awk ip timeout
    if [[ ${sub} != create ]]; then
        build_hosts
        key_hosts
    fi
    case "${sub}" in
        create) keys_create ;;
        trust)  keys_trust ;;
        deploy) keys_deploy ;;
        test)   keys_test ;;
        revoke) keys_revoke ;;
        setup)
            keys_create
            keys_trust
            keys_deploy
            keys_test
            log "chaves prontas; proximo passo: $0 check"
            ;;
    esac
}

# --------------------------------------------------------------- acoes
usage() {
    cat <<EOF
flux-loadtest ${VERSION} - teste de carga FluxSBC (WEB-1437)

Uso: $0 <acao> [opcoes]

Acoes:
  check [--fs-password] valida configuracao, dependencias, SSH e comandos remotos (somente leitura)
  smoke [--did N]       envia 1 chamada (hold 5 s) e mostra o resultado (com UAS_PORT, tambem
                        sobe o atendedor e confere se a chamada chegou a ele)
  run [opcoes]          executa o teste completo e gera o relatorio
  report <diretorio>    regenera o report.txt de uma execucao
  zabbix <sub>          integracao com o Zabbix (ZABBIX_* na configuracao):
      setup             cria os hosts e vincula os templates (--import-template importa o YAML)
      send <diretorio>  importa uma execucao (--force reenvia, --dry-run so mostra)
      check             testa a API e o trapper
  keys <sub> [opcoes]   chaves SSH da VM de teste para os servidores:
      create            gera a chave (SSH_KEY, SSH_KEY_TYPE); nao sobrescreve uma existente
      trust             grava as chaves de host (ssh-keyscan) apos conferencia
      deploy            instala a chave publica no authorized_keys do SSH_USER, restrita
                        a VM (from=IP, no-pty, sem encaminhamentos); pede senha
      test              confirma o acesso por chave e o sudo -n
      revoke            remove a chave dos servidores (fim do teste)
      setup             create + trust + deploy + test

Opcoes gerais:
  -c, --config FILE     configuracao (padrao: loadtest.conf ao lado do script)

Opcoes do keys:
      --key CAMINHO     sobrescreve SSH_KEY (caminho absoluto)
      --type TIPO       ed25519 (padrao) | rsa (4096 bits)
      --comment TEXTO   comentario da chave (padrao: flux-loadtest@<host>-<data>)
      --passphrase      pede passphrase (exige ssh-agent no run)
      --from IPs        from= do authorized_keys (padrao: IP de origem da rota ate cada servidor)
      --via USUARIO     primeiro acesso com outro usuario + sudo (ex.: root sem senha liberada)
      --known-hosts F   known_hosts dedicado (sobrescreve SSH_KNOWN_HOSTS)
      --write-config    grava SSH_KEY / SSH_KNOWN_HOSTS no arquivo de configuracao
  -y, --yes             nao pede confirmacao

Opcoes do run:
  -w, --window SEG      janela de envio de chamadas (padrao 300)
  -n, --calls N         total de chamadas; 0 = limitado so pela janela (padrao 0)
  -r, --cps N           chamadas por segundo alvo (obrigatorio com sip)
      --cps-start N     CPS inicial da rampa (padrao: 10% do alvo)
      --ramp-step N     incremento de CPS por degrau (padrao: --cps-start)
      --ramp-interval S intervalo entre degraus (padrao 10)
  -l, --max-concurrent N  limite de chamadas simultaneas (padrao: cps x (hold+4) x 1.2)
  -H, --hold SEG        duracao da chamada atendida antes do BYE (padrao 30)
  -M, --media MODO      rtp (SIPp envia G.711 a-law; com UAS_PORT o atendedor tambem envia)
                        | none (sem RTP nos SIPp) (padrao rtp)
  -t, --tests LISTA     sip,web,mysql (padrao sip,web; mysql = sysbench)
      --web-duration S  duracao de cada alvo web (padrao 30)
      --web-conns N     conexoes simultaneas do wrk (padrao 50)
      --web-threads N   threads do wrk (padrao 4)
      --mysql-duration S  duracao do sysbench (padrao 60)
      --baseline S      sobrescreve BASELINE_SECONDS
      --cooldown S      sobrescreve COOLDOWN_SECONDS
      --label TEXTO     rotulo da execucao (vai no nome do diretorio)
      --did N           envia todas as chamadas para um unico DID
      --dry-run         mostra o plano e os comandos, sem executar
      --confirm-prod    obrigatorio: confirma execucao no ambiente de producao
      --fs-password     pede a senha do fs_cli (event socket) no terminal; alternativa
                        sem interacao: FS_CLI_PASSWORD_FILE na configuracao
  -y, --yes             nao pede confirmacao interativa

Exemplos:
  $0 keys setup --via admin --write-config
  $0 check
  $0 smoke --did 551130001000
  $0 run --confirm-prod -r 100 -H 30 -w 600 --label c3000-cps100
  $0 run --confirm-prod -t web,mysql --web-conns 100
EOF
}

parse_run_opts() {
    while (($# > 0)); do
        case "$1" in
            -w|--window)        OPT_WINDOW=${2:-}; shift 2 ;;
            -n|--calls)         OPT_CALLS=${2:-}; shift 2 ;;
            -r|--cps)           OPT_CPS=${2:-}; shift 2 ;;
            --cps-start)        OPT_CPS_START=${2:-}; shift 2 ;;
            --ramp-step)        OPT_RAMP_STEP=${2:-}; shift 2 ;;
            --ramp-interval)    OPT_RAMP_INTERVAL=${2:-}; shift 2 ;;
            -l|--max-concurrent) OPT_LIMIT=${2:-}; shift 2 ;;
            -H|--hold)          OPT_HOLD=${2:-}; shift 2 ;;
            -M|--media)         OPT_MEDIA=${2:-}; shift 2 ;;
            -t|--tests)         OPT_TESTS=${2:-}; shift 2 ;;
            --web-duration)     OPT_WEB_DURATION=${2:-}; shift 2 ;;
            --web-conns)        OPT_WEB_CONNS=${2:-}; shift 2 ;;
            --web-threads)      OPT_WEB_THREADS=${2:-}; shift 2 ;;
            --mysql-duration)   OPT_MYSQL_DURATION=${2:-}; shift 2 ;;
            --baseline)         OPT_BASELINE=${2:-}; shift 2 ;;
            --cooldown)         OPT_COOLDOWN=${2:-}; shift 2 ;;
            --label)            OPT_LABEL=${2:-}; shift 2 ;;
            --did)              OPT_DID=${2:-}; shift 2 ;;
            --dry-run)          OPT_DRY_RUN=1; shift ;;
            --confirm-prod)     OPT_CONFIRM_PROD=1; shift ;;
            --fs-password)      OPT_FS_PASSWORD_PROMPT=1; shift ;;
            -y|--yes)           OPT_YES=1; shift ;;
            *) usage >&2; die "${E_USAGE}" "opcao invalida: $1" ;;
        esac
    done
}

validate_run_opts() {
    local v t
    for v in OPT_WINDOW OPT_CALLS OPT_RAMP_INTERVAL OPT_HOLD OPT_WEB_DURATION OPT_WEB_CONNS \
             OPT_WEB_THREADS OPT_MYSQL_DURATION; do
        is_uint "${!v}" || die "${E_USAGE}" "${v#OPT_} deve ser inteiro: '${!v}'"
    done
    [[ -z ${OPT_BASELINE} ]] || { is_uint "${OPT_BASELINE}" || die "${E_USAGE}" "--baseline invalido"; CFG[BASELINE_SECONDS]=${OPT_BASELINE}; }
    [[ -z ${OPT_COOLDOWN} ]] || { is_uint "${OPT_COOLDOWN}" || die "${E_USAGE}" "--cooldown invalido"; CFG[COOLDOWN_SECONDS]=${OPT_COOLDOWN}; }
    [[ ${OPT_LABEL} =~ ^[A-Za-z0-9._-]{0,40}$ ]] || die "${E_USAGE}" "--label: use ate 40 caracteres [A-Za-z0-9._-]"
    [[ ${OPT_MEDIA} == rtp || ${OPT_MEDIA} == none ]] || die "${E_USAGE}" "--media deve ser rtp ou none"
    IFS=',' read -ra v <<< "${OPT_TESTS}"
    ((${#v[@]} > 0)) || die "${E_USAGE}" "--tests vazio"
    for t in "${v[@]}"; do
        [[ ${t} == sip || ${t} == web || ${t} == mysql ]] || die "${E_USAGE}" "--tests: valor invalido '${t}'"
    done

    if has_test sip; then
        is_uint "${OPT_CPS}" && ((OPT_CPS >= 1)) || die "${E_USAGE}" "--cps obrigatorio (inteiro >= 1) com o teste sip"
        ((OPT_WINDOW >= 10)) || die "${E_USAGE}" "--window minimo: 10 s"
        ((OPT_HOLD >= 1)) || die "${E_USAGE}" "--hold minimo: 1 s"
        ((OPT_RAMP_INTERVAL >= 1)) || die "${E_USAGE}" "--ramp-interval minimo: 1 s"
        [[ -n ${OPT_CPS_START} ]] || OPT_CPS_START=$(( OPT_CPS / 10 > 0 ? OPT_CPS / 10 : 1 ))
        is_uint "${OPT_CPS_START}" && ((OPT_CPS_START >= 1)) || die "${E_USAGE}" "--cps-start invalido"
        ((OPT_CPS_START <= OPT_CPS)) || OPT_CPS_START=${OPT_CPS}
        [[ -n ${OPT_RAMP_STEP} ]] || OPT_RAMP_STEP=${OPT_CPS_START}
        is_uint "${OPT_RAMP_STEP}" && ((OPT_RAMP_STEP >= 1)) || die "${E_USAGE}" "--ramp-step invalido"
        [[ -n ${OPT_LIMIT} ]] || OPT_LIMIT=$(( (OPT_CPS * (OPT_HOLD + 4) * 12 + 9) / 10 ))
        is_uint "${OPT_LIMIT}" && ((OPT_LIMIT >= 1)) || die "${E_USAGE}" "--max-concurrent invalido"
    fi
    if has_test web; then
        require_cfg WEB_BASE_URL
        [[ ${CFG[WEB_BASE_URL]} =~ ^https?://[^/[:space:]]+ ]] || die "${E_CONFIG}" "WEB_BASE_URL invalida"
        ((OPT_WEB_CONNS >= OPT_WEB_THREADS && OPT_WEB_THREADS >= 1)) || die "${E_USAGE}" "--web-conns deve ser >= --web-threads >= 1"
    fi
    if has_test mysql; then
        require_cfg MYSQL_BENCH_HOST MYSQL_BENCH_USER MYSQL_BENCH_PASSWORD_FILE MYSQL_BENCH_DB
        [[ ${CFG[MYSQL_BENCH_DB]} =~ ^[A-Za-z0-9_]+$ ]] || die "${E_CONFIG}" "MYSQL_BENCH_DB invalido"
        [[ ${CFG[MYSQL_BENCH_DB],,} != "${CFG[FLUX_DB_NAME],,}" ]] \
            || die "${E_CONFIG}" "MYSQL_BENCH_DB nao pode ser o schema do Flux (${CFG[FLUX_DB_NAME]})"
        [[ -r ${CFG[MYSQL_BENCH_PASSWORD_FILE]} ]] || die "${E_CONFIG}" "MYSQL_BENCH_PASSWORD_FILE ilegivel"
    fi
}

print_plan() {
    local est_conc est_calls est_vm_gb
    printf '\n== Plano da execucao %s\n' "${RUN_ID}"
    printf '  testes             %s\n' "${OPT_TESTS}"
    printf '  servidores         '
    local id
    for id in "${HOST_IDS[@]}"; do printf '%s=%s ' "${id}" "${HOST_ADDR[${id}]}"; done
    printf '\n  baseline/cooldown  %s s / %s s\n' "${CFG[BASELINE_SECONDS]}" "${CFG[COOLDOWN_SECONDS]}"
    if has_test sip; then
        est_conc=$((OPT_CPS * OPT_HOLD))
        est_calls=$((OPT_CPS * OPT_WINDOW))
        ((OPT_CALLS > 0 && OPT_CALLS < est_calls)) && est_calls=${OPT_CALLS}
        printf '  SIP destino        %s:%s a partir de %s:%s\n' "${SIP_TARGET_IP}" "${SIP_TARGET_PORT}" "${LOCAL_IP}" "${CFG[SIP_LOCAL_PORT]}"
        printf '  DIDs               %s\n' "$([[ -n ${OPT_DID} ]] && printf 'unico: %s' "${OPT_DID}" || printf '%s (%s)' "${CFG[DID_FILE]}" "${DID_COUNT}")"
        printf '  CPS                %s -> %s (+%s a cada %s s)\n' "${OPT_CPS_START}" "${OPT_CPS}" "${OPT_RAMP_STEP}" "${OPT_RAMP_INTERVAL}"
        printf '  janela / chamadas  %s s / %s\n' "${OPT_WINDOW}" "$( ((OPT_CALLS > 0)) && printf '%s' "${OPT_CALLS}" || printf 'sem limite')"
        printf '  hold / midia       %s s / %s\n' "${OPT_HOLD}" "${OPT_MEDIA}"
        printf '  simultaneas        ~%s em regime (limite %s)\n' "${est_conc}" "${OPT_LIMIT}"
        if ((OPT_LIMIT < est_conc)); then
            warn "limite de simultaneas (${OPT_LIMIT}) abaixo do regime esperado (${est_conc}): o CPS real ficara menor"
        fi
        if uas_enabled; then
            printf '  atendedor          SIPp UAS em %s:%s (DIDs DIRECT-IP), RTP a partir de %s, midia %s\n' \
                "${LOCAL_IP}" "${CFG[UAS_PORT]}" "${CFG[UAS_RTP_PORT_BASE]}" \
                "$([[ ${OPT_MEDIA} == rtp ]] && printf 'G.711 nos dois sentidos' || printf 'sem RTP')"
        elif [[ ${OPT_MEDIA} == rtp ]]; then
            est_vm_gb=$(awk -v c="${est_calls}" -v h="${OPT_HOLD}" -v g="${CFG[VM_GREETING_SECONDS]}" -v b="${CFG[VM_BYTES_PER_SECOND]}" \
                'BEGIN { s = h - g; if (s < 0) s = 0; printf "%.1f", c * s * b / 1e9 }')
            printf '  caixa postal       ~%s chamadas, ~%s GB gravados nos FS (WAV 8 kHz 16 bit)\n' "${est_calls}" "${est_vm_gb}"
        else
            printf '  caixa postal       sem RTP de origem: o FS tende a encerrar por silencio (BYE remoto)\n'
        fi
    fi
    if has_test web; then
        printf '  web                %s (estatico %s, php %s%s) %s s x %s conexoes\n' "${CFG[WEB_BASE_URL]}" \
            "${CFG[WEB_STATIC_PATH]}" "${CFG[WEB_PHP_PATH]}" "${CFG[WEB_EXTRA_PATH]:+, extra ${CFG[WEB_EXTRA_PATH]}}" \
            "${OPT_WEB_DURATION}" "${OPT_WEB_CONNS}"
    fi
    if has_test mysql; then
        printf '  mysql              sysbench em %s:%s schema %s, %s threads, %s s\n' "${CFG[MYSQL_BENCH_HOST]}" \
            "${CFG[MYSQL_BENCH_PORT]}" "${CFG[MYSQL_BENCH_DB]}" "${CFG[MYSQL_BENCH_THREADS]}" "${OPT_MYSQL_DURATION}"
    fi
    printf '  limites            cpu>%s%% mem>%s%% disco_livre<%s%% falha_sip>%s%% replicacao>%ss nucleo>%s (0=off), %s amostras\n' \
        "${CFG[GUARD_MAX_CPU_PCT]}" "${CFG[GUARD_MAX_MEM_PCT]}" "${CFG[GUARD_MIN_DISK_FREE_PCT]}" \
        "${CFG[GUARD_MAX_FAIL_PCT]}" "${CFG[GUARD_MAX_REPL_LAG]}" "${CFG[GUARD_MAX_CORE_PCT]}" "${CFG[GUARD_HITS]}"
    printf '  limites cluster    no nao Synced, sem quorum, flow_control>%s%% (0=off), cluster_size<%s (0=off)\n' \
        "${CFG[GUARD_MAX_WSREP_FC_PCT]}" "${CFG[GUARD_MIN_WSREP_CLUSTER_SIZE]}"
    printf '  resultados         %s\n\n' "${RUN_DIR}"
}

save_run_env() {
    {
        printf 'execucao=%s\n' "${RUN_ID}"
        printf 'inicio=%(%F %T %z)T\n' -1
        printf 'vm_teste=%s (%s vCPU, %s MB)\n' "$(uname -n)" "$(nproc)" "$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
        printf 'testes=%s\n' "${OPT_TESTS}"
        if has_test sip; then
            printf 'sip_destino=%s:%s\n' "${SIP_TARGET_IP}" "${SIP_TARGET_PORT}"
            printf 'sip_origem=%s:%s\n' "${LOCAL_IP}" "${CFG[SIP_LOCAL_PORT]}"
            printf 'cps=%s (rampa %s +%s/%ss)\n' "${OPT_CPS}" "${OPT_CPS_START}" "${OPT_RAMP_STEP}" "${OPT_RAMP_INTERVAL}"
            printf 'janela_s=%s\nchamadas=%s\nhold_s=%s\nmidia=%s\nlimite_simultaneas=%s\n' \
                "${OPT_WINDOW}" "${OPT_CALLS}" "${OPT_HOLD}" "${OPT_MEDIA}" "${OPT_LIMIT}"
            printf 'dids=%s\n' "${OPT_DID:-${DID_COUNT} de ${CFG[DID_FILE]}}"
            if uas_enabled; then
                printf 'atendedor=%s:%s\n' "${LOCAL_IP}" "${CFG[UAS_PORT]}"
            else
                printf 'atendedor=nenhum (DID atendido no FS)\n'
            fi
        fi
        if has_test web; then
            printf 'web=%s conexoes=%s threads=%s duracao_s=%s\n' "${CFG[WEB_BASE_URL]}" "${OPT_WEB_CONNS}" "${OPT_WEB_THREADS}" "${OPT_WEB_DURATION}"
        fi
        if has_test mysql; then
            printf 'mysql_bench=%s:%s/%s threads=%s duracao_s=%s\n' "${CFG[MYSQL_BENCH_HOST]}" "${CFG[MYSQL_BENCH_PORT]}" \
                "${CFG[MYSQL_BENCH_DB]}" "${CFG[MYSQL_BENCH_THREADS]}" "${OPT_MYSQL_DURATION}"
        fi
        printf 'intervalo_amostra_s=%s\n' "${CFG[SAMPLE_INTERVAL]}"
    } > "${RUN_DIR}/run.env"
    write_hosts_tsv
}

# hosts.tsv: id, papel, endereco, nome (o nome vem do check_ssh_all)
write_hosts_tsv() {
    local id
    for id in "${HOST_IDS[@]}"; do
        printf '%s\t%s\t%s\t%s\n' "${id}" "${HOST_ROLE[${id}]}" "${HOST_ADDR[${id}]}" "${HOST_NAME[${id}]:-}"
    done > "${RUN_DIR}/hosts.tsv"
    printf 'gen\tgen\t%s\t%s\n' "${LOCAL_IP:-local}" "$(uname -n)" >> "${RUN_DIR}/hosts.tsv"
}

check_ssh_all() {
    local id t0 rts ok=1
    : > "${1:-/dev/null}"
    for id in "${HOST_IDS[@]}"; do
        t0=$(now)
        if rts=$(remote "${id}" 'date +%s; uname -n' 2>/dev/null) && [[ ${rts} =~ ^([0-9]+)$'\n'(.+)$ ]]; then
            rts=${BASH_REMATCH[1]}
            HOST_NAME[${id}]=${BASH_REMATCH[2]}
            printf '%-10s %-16s %-24s offset %+d s\n' "${id}" "${HOST_ADDR[${id}]}" "${HOST_NAME[${id}]}" \
                $((rts - t0)) >> "${1:-/dev/null}"
            if ((rts - t0 > 2 || t0 - rts > 2)); then
                warn "${id}: relogio difere $((rts - t0)) s da VM de teste (as fases podem ficar desalinhadas; use NTP/chrony)"
            fi
        else
            warn "${id} (${HOST_ADDR[${id}]}): SSH falhou"
            ok=0
        fi
    done
    ((ok))
}

cmd_check() {
    local id role cmd res
    check_local_deps ssh sipp wrk curl python3 awk sed shuf timeout ip nice
    uas_enabled && check_local_deps ss
    build_hosts
    build_ssh
    load_fs_password
    parse_sip_target
    LOCAL_IP=$(detect_local_ip)
    local sipp_ver
    sipp_ver=$(sipp -v 2>&1 || true)
    [[ ${sipp_ver} =~ (SIPp v[^[:space:]]+) ]] && sipp_ver=${BASH_REMATCH[1]} || sipp_ver="SIPp ?"
    printf '\n== VM de teste\n'
    printf '  %s, %s vCPU, %s MB, ulimit -n %s, %s\n' "$(uname -n)" "$(nproc)" \
        "$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)" "$(ulimit -n)" "${sipp_ver}"
    printf '  IP de origem SIP: %s -> %s:%s\n' "${LOCAL_IP:-?}" "${SIP_TARGET_IP}" "${SIP_TARGET_PORT}"
    printf '  O destino precisa aceitar a origem: OpenSIPS (address, grp 10) ou, direto no FS,\n'
    printf '  a ACL de entrada do profile. Atras de NAT, libere o IP publico, nao este.\n'
    if uas_enabled; then
        printf '  Atendedor (UAS): %s:%s/udp, porta %s; RTP a partir de %s\n' "${LOCAL_IP:-?}" "${CFG[UAS_PORT]}" \
            "$(uas_port_free && printf 'livre' || printf 'EM USO')" "${CFG[UAS_RTP_PORT_BASE]}"
        printf '  Os DIDs precisam estar como DIRECT-IP (call_type 2) com extensions=<IP desta VM\n'
        printf '  visto pelo FS>:%s; o firewall precisa liberar SIP e RTP dos FS para esta VM.\n' "${CFG[UAS_PORT]}"
    fi
    if [[ -n ${CFG[DID_FILE]} ]]; then
        local tmp_csv
        tmp_csv=$(mktemp)
        build_calls_csv "${tmp_csv}" "" && printf '  DIDs validos: %s\n' "${DID_COUNT}"
        rm -f "${tmp_csv}"
    fi
    command -v sysbench >/dev/null 2>&1 && printf '  sysbench: %s\n' "$(sysbench --version 2>&1)" || printf '  sysbench: ausente (necessario so para --tests mysql)\n'

    printf '\n== SSH e relogio\n'
    local clk
    clk=$(mktemp)
    check_ssh_all "${clk}" || true
    sed 's/^/  /' "${clk}"
    rm -f "${clk}"

    printf '\n== Comandos remotos\n'
    for id in "${HOST_IDS[@]}"; do
        role=${HOST_ROLE[${id}]}
        case "${role}" in
            # max-sessions / sessions-per-second limitam o teste (padrao do repo: 1000 / 30 por no)
            fs)       cmd="$(fs_prelude)"$'\n'"fsx status | grep -E 'is ready|session\\(s\\) - peak|per Sec|session\\(s\\) max|idle cpu|rror|uth'; df -P $(printf '%q' "${CFG[FS_DISK_PATH]}") | tail -1" ;;
            opensips) cmd="${CFG[OPENSIPS_MI_CMD]} get_statistics active_dialogs; ${CFG[OPENSIPS_MI_CMD]} lb_list | head -20" ;;
            db)       cmd="${CFG[MYSQL_CLI_CMD]} -N -e 'SELECT @@hostname, @@version, @@read_only'"
                      cmd+="; ${CFG[MYSQL_CLI_CMD]} -N -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready')\""
                      cmd+="; ${CFG[MYSQL_CLI_CMD]} -e 'SHOW REPLICA STATUS\G' | grep -E 'Source_Host|Running:|Seconds_Behind' || echo 'sem replicacao assincrona (normal em Percona XtraDB Cluster)'"
                      [[ -n ${CFG[DB_VIP]} ]] && cmd+="; ip -o -4 addr show | grep -q ' ${CFG[DB_VIP]}/' && echo 'VIP ${CFG[DB_VIP]}: ativo neste no' || echo 'VIP ${CFG[DB_VIP]}: em outro no'"
                      ;;
            web)      cmd="pgrep -c nginx; pgrep -c php-fpm"
                      [[ -n ${CFG[NGINX_STATUS_URL]} ]] && cmd+="; curl -fsk -m 3 $(printf '%q' "${CFG[NGINX_STATUS_URL]}") | head -1"
                      [[ -n ${CFG[FPM_STATUS_URL]} ]] && cmd+="; curl -fsk -m 3 $(printf '%q' "${CFG[FPM_STATUS_URL]}") | head -c 200"
                      ;;
        esac
        printf -- '-- %s (%s)\n' "${id}" "${role}"
        if res=$(remote_script "${id}" "bash --version | head -1"$'\n'"${cmd}" 2>&1); then
            printf '%s\n' "${res}" | sed 's/^/  /'
        else
            printf '%s\n' "${res}" | sed 's/^/  FALHA: /'
        fi
        if [[ ${role} == fs ]] && ! grep -q 'is ready' <<< "${res}"; then
            printf '  fs_cli sem resposta: confira a senha do event socket (FS_CLI_PASSWORD_FILE ou --fs-password)\n'
            printf '  e se o usuario SSH pode rodar o fs_cli (FS_CLI_CMD="%s")\n' "${CFG[FS_CLI_CMD]}"
        fi
    done
    if zbx_enabled || [[ -n ${CFG[ZABBIX_API_URL]} ]]; then
        printf '\n== Zabbix\n'
        cmd_zabbix check 2>&1 | sed 's/^/  /' || true
    fi
    printf '\nSomente leitura: nada foi alterado nos servidores.\n'
}

cmd_smoke() {
    local dir rc=0
    check_local_deps sipp python3 awk sed shuf ip
    uas_enabled && check_local_deps ss
    parse_sip_target
    LOCAL_IP=$(detect_local_ip)
    [[ -n ${LOCAL_IP} ]] || die "${E_CONFIG}" "sem rota para ${SIP_TARGET_IP}; defina SIP_LOCAL_IP"
    if [[ -z ${OPT_DID} ]]; then
        require_cfg DID_FILE
        OPT_DID=$(tr -d '\r' < "${CFG[DID_FILE]}" | grep -m1 -E '^\+?[0-9]{4,20}$' || true)
        [[ -n ${OPT_DID} ]] || die "${E_CONFIG}" "nenhum DID valido em ${CFG[DID_FILE]}"
    fi
    RUN_ID="smoke-$(date +%Y%m%d-%H%M%S)"
    dir=$(mktemp -d)
    OPT_HOLD=5 OPT_CPS=1 OPT_CPS_START=1 OPT_CALLS=1 OPT_LIMIT=1 OPT_WINDOW=30
    [[ ${OPT_MEDIA} == rtp || ${OPT_MEDIA} == none ]] || die "${E_USAGE}" "--media deve ser rtp ou none"
    prepare_sip "${dir}" "${LOCAL_IP}"
    if uas_enabled; then
        uas_port_free || die "${E_CONFIG}" "UAS_PORT ${CFG[UAS_PORT]}/udp ja esta em uso nesta VM"
        prepare_uas "${dir}/uas" "${LOCAL_IP}" "${dir}/tone.al"
        trap '[[ -z ${UAS_PID} ]] || kill -TERM "${UAS_PID}" 2>/dev/null || true' EXIT
        start_uas "${dir}/uas"
    fi
    log "smoke: 1 chamada para ${OPT_DID} via ${SIP_TARGET_IP}:${SIP_TARGET_PORT} (origem ${LOCAL_IP}, midia ${OPT_MEDIA})"
    (cd "${dir}" && sipp "${SIPP_ARGS[@]}" > /dev/null 2> "${dir}/sipp.stderr") || rc=$?
    stop_uas
    RUN_DIR=${dir}
    mkdir -p "${dir}/sip"
    mv "${dir}"/stats.csv "${dir}"/errors.log "${dir}"/actions.log "${dir}"/screen.log "${dir}/sip/" 2>/dev/null || true
    printf '\n'
    report_sip "${dir}"
    if uas_enabled; then
        printf '\n  Atendedor (%s:%s):\n' "${LOCAL_IP}" "${CFG[UAS_PORT]}"
        report_uas "${dir}" | sed 's/^/  /'
    fi
    if sip_real_errors "${dir}/sip/errors.log" | grep -q 'Aborting\|timeout'; then
        printf '\n  Primeiro erro:\n'
        sip_real_errors "${dir}/sip/errors.log" | grep -m1 -A12 'Aborting\|timeout' | sed 's/^/    /' || true
    fi
    if [[ -n $(sip_real_errors "${dir}/sipp.stderr") ]]; then
        printf '\n  stderr do SIPp: %s\n' "$(sip_real_errors "${dir}/sipp.stderr" | head -c 300)"
    fi
    printf '\n  arquivos: %s\n' "${dir}"
    RUN_DIR=""
    ((rc == 0)) && log "smoke OK" || die "${E_REMOTE}" "smoke falhou (rc=${rc})"
}

cmd_run() {
    local max_coll
    parse_run_opts "$@"
    validate_run_opts
    local -a deps=(ssh curl awk sed timeout nice)
    has_test sip && deps+=(sipp python3 shuf ip)
    has_test sip && uas_enabled && deps+=(ss)
    has_test web && deps+=(wrk)
    has_test mysql && deps+=(sysbench mysql)
    zbx_enabled && [[ ${CFG[ZABBIX_LIVE]} == 1 ]] && deps+=(python3)
    check_local_deps "${deps[@]}"
    build_hosts
    build_ssh

    RUN_ID="$(date +%Y%m%d-%H%M%S)${OPT_LABEL:+-${OPT_LABEL}}"
    RUN_DIR="${CFG[RESULTS_DIR]}/${RUN_ID}"
    LOCAL_IP=""
    if has_test sip; then
        parse_sip_target
        LOCAL_IP=$(detect_local_ip)
        [[ -n ${LOCAL_IP} ]] || die "${E_CONFIG}" "sem rota para ${SIP_TARGET_IP}; defina SIP_LOCAL_IP"
        local tmp
        tmp=$(mktemp)
        build_calls_csv "${tmp}" "${OPT_DID}"
        rm -f "${tmp}"
        if uas_enabled && ! uas_port_free; then
            die "${E_CONFIG}" "UAS_PORT ${CFG[UAS_PORT]}/udp ja esta em uso nesta VM"
        fi
    fi

    print_plan
    if ((OPT_DRY_RUN)); then
        if has_test sip; then
            sipp_args "${RUN_DIR}/sip" "${LOCAL_IP}"
            printf 'sipp'
            printf ' %q' "${SIPP_ARGS[@]}"
            printf '\n'
            if uas_enabled; then
                uas_args "${RUN_DIR}/uas" "${LOCAL_IP}"
                printf 'sipp'
                printf ' %q' "${UAS_ARGS[@]}"
                printf '\n'
            fi
        fi
        log "dry-run: nada foi executado"
        RUN_DIR=""
        return 0
    fi

    ((OPT_CONFIRM_PROD)) || die "${E_USAGE}" "ambiente de producao: repita com --confirm-prod apos revisar o plano (ou use --dry-run)"
    load_fs_password
    if ((OPT_YES == 0)) && [[ -t 0 ]]; then
        local ans
        read -r -p "Digite PRODUCAO para iniciar: " ans
        [[ ${ans} == PRODUCAO ]] || die "${E_ABORT}" "cancelado pelo operador"
    fi

    install -d -m 0750 "${RUN_DIR}" || die "${E_CONFIG}" "nao foi possivel criar ${RUN_DIR}"
    exec > >(tee -a "${RUN_DIR}/console.log") 2>&1
    trap on_exit EXIT
    trap on_interrupt INT TERM
    save_run_env

    log "verificando SSH"
    check_ssh_all "${RUN_DIR}/clock.tsv" || die "${E_REMOTE}" "SSH indisponivel em algum servidor; nada foi iniciado"
    write_hosts_tsv
    if has_test sip; then
        prepare_sip "${RUN_DIR}/sip" "${LOCAL_IP}"
        prepare_uas "${RUN_DIR}/uas" "${LOCAL_IP}" "${RUN_DIR}/sip/tone.al"
    fi

    snapshot pre
    max_coll=$(( CFG[BASELINE_SECONDS] + CFG[COOLDOWN_SECONDS] + OPT_WINDOW + OPT_HOLD + 180
               + (OPT_WEB_DURATION + 15) * 3 + OPT_MYSQL_DURATION * 2 + 600 ))
    start_collectors "${max_coll}"
    zabbix_live_start

    phase_begin baseline
    wait_seconds "${CFG[BASELINE_SECONDS]}"
    phase_end

    if has_test sip && [[ -z ${ABORT_REASON} ]]; then
        run_sip_phase "${LOCAL_IP}"
        [[ -n ${ABORT_REASON} ]] || wait_seconds 15
    fi
    if has_test mysql && [[ -z ${ABORT_REASON} ]]; then
        run_mysql_phase
        [[ -n ${ABORT_REASON} ]] || wait_seconds 15
    fi
    if has_test web && [[ -z ${ABORT_REASON} ]]; then
        run_web_phase
    fi

    # cooldown roda mesmo apos abort: mostra o retorno ao normal
    local saved_reason=${ABORT_REASON}
    ABORT_REASON=""
    phase_begin cooldown
    wait_seconds "${CFG[COOLDOWN_SECONDS]}"
    phase_end
    ABORT_REASON=${saved_reason}

    stop_collectors
    snapshot post
    [[ -z ${ABORT_REASON} ]] || printf '%s\n' "${ABORT_REASON}" > "${RUN_DIR}/abort.txt"
    generate_report "${RUN_DIR}"
    zabbix_live_stop
    tar -C "${CFG[RESULTS_DIR]}" -czf "${RUN_DIR}.tar.gz" "${RUN_ID}" \
        && log "pacote: ${RUN_DIR}.tar.gz"
    if [[ -n ${ABORT_REASON} ]]; then
        warn "execucao interrompida: ${ABORT_REASON}"
        exit "${E_ABORT}"
    fi
    log "concluido"
}

main() {
    local action=${1:-} config="${SCRIPT_DIR}/loadtest.conf"
    (($# > 0)) && shift
    local -a rest=()
    while (($# > 0)); do
        case "$1" in
            -c|--config) config=${2:-}; shift 2 ;;
            *) rest+=("$1"); shift ;;
        esac
    done
    case "${action}" in
        ""|-h|--help|help) usage; exit 0 ;;
        check|smoke|run|report|keys|zabbix) ;;
        *) usage >&2; die "${E_USAGE}" "acao invalida: ${action}" ;;
    esac
    if [[ ${action} == report ]]; then
        ((${#rest[@]} == 1)) || die "${E_USAGE}" "uso: $0 report <diretorio-da-execucao>"
        generate_report "${rest[0]%/}"
        return 0
    fi
    CONFIG_FILE=${config}
    load_config "${config}"
    validate_config
    case "${action}" in
        keys) cmd_keys "${rest[@]+"${rest[@]}"}" ;;
        check)
            local opt
            for opt in "${rest[@]+"${rest[@]}"}"; do
                case "${opt}" in
                    --fs-password) OPT_FS_PASSWORD_PROMPT=1 ;;
                    *) usage >&2; die "${E_USAGE}" "opcao invalida para check: ${opt}" ;;
                esac
            done
            cmd_check
            ;;
        smoke)
            if ((${#rest[@]} > 0)); then parse_run_opts "${rest[@]}"; fi
            cmd_smoke
            ;;
        run) cmd_run "${rest[@]+"${rest[@]}"}" ;;
        zabbix) cmd_zabbix "${rest[@]+"${rest[@]}"}" ;;
    esac
}

main "$@"
