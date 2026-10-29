#!/usr/bin/env bash
#
# diag-fs-gargalo.sh - diagnostico SOMENTE LEITURA do teto de CPS por FreeSWITCH (WEB-1437)
#
# Roda no gerador (.165) e consulta de uma vez, por SSH e com a configuracao do flux-loadtest,
# todos os FS (FS_HOSTS) e bancos (DB_HOSTS). Grava o resultado em um arquivo Markdown.
#
# Por FS:
#   - perfil SIP "default": manage-presence, odbc-dsn e parametros de presenca (xml_locate)
#   - core db e limites do switch.conf (xml_locate)
#   - secao do DSN no /etc/odbc.ini, driver ODBC e pacotes instalados (senhas mascaradas)
#   - RTT ate o servidor do DSN e ate cada DB_HOSTS (ping)
#   - custo de uma consulta pelo mesmo caminho ODBC do FS (isql, N x SELECT 1)
# Por banco:
#   - instrucoes e tempo por host cliente (performance_schema)
#   - no primeiro banco: linhas de presenca e registro por hostname
# Com --janela SEG: segunda foto do performance_schema no fim da janela e delta por host
# cliente e por consulta. Com --sob-carga SEG: os FS repetem ping e isql SEG segundos depois
# do inicio, com as chamadas e as threads mais carregadas do FS naquele momento. Dispare a
# escada logo depois de iniciar: a medicao ociosa cai no baseline do flux-loadtest.
#
# Uso (no .165):
#   bash diag-fs-gargalo.sh [-c /etc/flux-loadtest/loadtest.conf] [-o arquivo.md]
#                           [--janela SEG] [--sob-carga SEG] [--ping N] [--consultas N]
#                           [--schema NOME]
#
# Nada e alterado nos servidores. Carga gerada: ping de 5 pacotes/s e N consultas SELECT 1 por
# FS (padrao 2000, cerca de 1 s de banco); no banco, leituras do performance_schema.
# Requisitos: os do flux-loadtest (usuario SSH, sudo -n para fs_cli, MYSQL_CLI_CMD com SELECT
# em performance_schema e no schema do Flux) e isql (pacote unixodbc) nos FS.
#
# Saida: 0 = todos os servidores responderam; 5 = algum servidor falhou (detalhes no arquivo).

set -Eeuo pipefail
export LC_ALL=C

readonly E_USAGE=2 E_CONFIG=3 E_DEPS=4 E_REMOTE=5

log()  { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
warn() { printf '[%(%H:%M:%S)T] AVISO: %s\n' -1 "$*" >&2; }
die()  { local code=$1; shift; printf '[%(%H:%M:%S)T] ERRO: %s\n' -1 "$*" >&2; exit "${code}"; }

usage() {
    cat <<'EOF'
uso: diag-fs-gargalo.sh [opcoes]

  -c ARQUIVO        configuracao do flux-loadtest (padrao /etc/flux-loadtest/loadtest.conf)
  -o ARQUIVO        resultado em Markdown (padrao ./diag-fs-AAAAmmdd-HHMMSS.md); nao sobrescreve
  --janela SEG      delta do performance_schema entre o inicio e SEG segundos depois (0 = so foto)
  --sob-carga SEG   FS repetem ping e isql SEG segundos depois do inicio (padrao: metade da janela)
  --ping N          pacotes de ping por alvo na medicao ociosa (padrao 200, 5/s)
  --consultas N     SELECT 1 pelo isql na medicao ociosa (padrao 2000)
  --schema NOME     schema das tabelas sip_* (padrao FLUX_DB_NAME da configuracao)
  -h, --help        esta ajuda

Exemplo, junto com a stfc-cps-escada50 (baseline de 120 s, degrau de 25 CPS entre 300 e 360 s):
  bash diag-fs-gargalo.sh --janela 420 --sob-carga 330
EOF
}

# So as chaves usadas aqui; as demais da configuracao do flux-loadtest sao ignoradas.
declare -A CFG=(
    [SSH_USER]="" [SSH_KEY]="" [SSH_PORT]=22 [SSH_OPTS]="" [SSH_KNOWN_HOSTS]=""
    [FS_HOSTS]="" [DB_HOSTS]="" [FS_CLI_CMD]="sudo -n fs_cli -x" [FS_CLI_PASSWORD_FILE]=""
    [MYSQL_CLI_CMD]="mysql" [FLUX_DB_NAME]="flux"
)

load_config() {
    local file=$1 line key val n=0
    [[ -r ${file} ]] || die "${E_CONFIG}" "configuracao nao encontrada ou ilegivel: ${file}"
    while IFS= read -r line || [[ -n ${line} ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ ${line} =~ ^[[:space:]]*(#|$) ]] && continue
        [[ ${line} =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "${E_CONFIG}" "${file}:${n}: linha invalida (use CHAVE=valor)"
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        [[ -n ${CFG[${key}]+x} ]] || continue
        if [[ ${val} =~ ^\"(.*)\"$ || ${val} =~ ^\'(.*)\'$ ]]; then
            val=${BASH_REMATCH[1]}
        fi
        CFG[${key}]=${val}
    done < "${file}"
}

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

OPT_CONF=/etc/flux-loadtest/loadtest.conf
OPT_OUT=""
OPT_WINDOW=0
OPT_LOAD=""
OPT_PING=200
OPT_QUERIES=2000
OPT_SCHEMA=""

parse_args() {
    while (($# > 0)); do
        case $1 in
            -c) (($# >= 2)) || die "${E_USAGE}" "-c exige um arquivo"; OPT_CONF=$2; shift 2 ;;
            -o) (($# >= 2)) || die "${E_USAGE}" "-o exige um arquivo"; OPT_OUT=$2; shift 2 ;;
            --janela) (($# >= 2)) || die "${E_USAGE}" "--janela exige segundos"; OPT_WINDOW=$2; shift 2 ;;
            --sob-carga) (($# >= 2)) || die "${E_USAGE}" "--sob-carga exige segundos"; OPT_LOAD=$2; shift 2 ;;
            --ping) (($# >= 2)) || die "${E_USAGE}" "--ping exige um numero"; OPT_PING=$2; shift 2 ;;
            --consultas) (($# >= 2)) || die "${E_USAGE}" "--consultas exige um numero"; OPT_QUERIES=$2; shift 2 ;;
            --schema) (($# >= 2)) || die "${E_USAGE}" "--schema exige um nome"; OPT_SCHEMA=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "${E_USAGE}" "opcao desconhecida: $1" ;;
        esac
    done
    in_range "${OPT_WINDOW}" 0 7200 || die "${E_USAGE}" "--janela: 0 a 7200 segundos"
    [[ -n ${OPT_LOAD} ]] || OPT_LOAD=$((OPT_WINDOW / 2))
    in_range "${OPT_LOAD}" 0 7200 || die "${E_USAGE}" "--sob-carga: 0 a 7200 segundos"
    in_range "${OPT_PING}" 10 2000 || die "${E_USAGE}" "--ping: 10 a 2000"
    in_range "${OPT_QUERIES}" 100 20000 || die "${E_USAGE}" "--consultas: 100 a 20000"
}

# in_range VALOR MIN MAX
in_range() { is_uint "$1" && (($1 >= $2 && $1 <= $3)); }

SSH_CMD=()
build_ssh() {
    local -a opts
    [[ -n ${CFG[SSH_USER]} ]] || die "${E_CONFIG}" "SSH_USER nao definido na configuracao"
    is_uint "${CFG[SSH_PORT]}" || die "${E_CONFIG}" "SSH_PORT invalido: ${CFG[SSH_PORT]}"
    read -ra opts <<< "${CFG[SSH_OPTS]}"
    SSH_CMD=(ssh -p "${CFG[SSH_PORT]}" "${opts[@]}")
    [[ -n ${CFG[SSH_KNOWN_HOSTS]} ]] && SSH_CMD+=(-o "UserKnownHostsFile=${CFG[SSH_KNOWN_HOSTS]}")
    if [[ -n ${CFG[SSH_KEY]} ]]; then
        [[ -r ${CFG[SSH_KEY]} ]] || die "${E_CONFIG}" "SSH_KEY ilegivel: ${CFG[SSH_KEY]}"
        SSH_CMD+=(-i "${CFG[SSH_KEY]}" -o IdentitiesOnly=yes)
    fi
}

# Senha do event socket: so pelo stdin do SSH, nunca em argumento, arquivo ou log.
FS_CLI_PASSWORD=""
load_fs_password() {
    local file=${CFG[FS_CLI_PASSWORD_FILE]} line
    [[ -n ${file} ]] || return 0
    [[ -r ${file} ]] || die "${E_CONFIG}" "FS_CLI_PASSWORD_FILE ilegivel: ${file}"
    IFS= read -r line < "${file}" || true
    FS_CLI_PASSWORD=${line%$'\r'}
    [[ -n ${FS_CLI_PASSWORD} ]] || die "${E_CONFIG}" "FS_CLI_PASSWORD_FILE vazio: ${file}"
}

# Preambulo dos scripts remotos do FS: fsx() = FS_CLI_CMD, com -p quando ha senha.
fs_prelude() {
    local -a w
    local x out="" added=0
    read -ra w <<< "${CFG[FS_CLI_CMD]}"
    for x in "${w[@]}"; do
        out+="$(printf '%q' "${x}") "
        if ((added == 0)) && [[ -n ${FS_CLI_PASSWORD} && ${x##*/} == fs_cli ]]; then
            # expande no servidor, nao aqui
            # shellcheck disable=SC2016
            out+='-p "${FSPW}" '
            added=1
        fi
    done
    printf 'FSPW=%q\n' "${FS_CLI_PASSWORD}"
    printf 'fsx() { timeout 20 %s"$@" 2>&1; }\n' "${out}"
}

# Funcoes comuns aos scripts remotos. mask esconde senhas de DSN e do odbc.ini.
remote_common() {
    cat <<'REMOTE'
set -uo pipefail
export LC_ALL=C
kv()  { printf '@kv %s\t%s\n' "$1" "$2"; }
sec() { printf '@sec %s\n' "$*"; }
mask() {
    sed -E -e 's/((pwd|password)[[:space:]]*=[[:space:]]*)[^;<"[:space:]]*/\1****/Ig' \
           -e 's#((odbc://)?[A-Za-z0-9_.-]+:[^:;<"[:space:]]+:)[^;<"[:space:]]+#\1****#g'
}
REMOTE
}

fs_script() {
    printf 'PING_N=%q\nQUERIES=%q\nDB_HOSTS=%q\nLOAD_AT=%q\n' \
        "${OPT_PING}" "${OPT_QUERIES}" "${CFG[DB_HOSTS]}" "${LOAD_AT}"
    remote_common
    fs_prelude
    cat <<'REMOTE'
TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "${TMPD}"' EXIT

# valor de <param name="NOME" value="..."/> em um trecho de XML
param_val() {
    grep -oE "name=\"$1\"[[:space:]]+value=\"[^\"]*\"" <<< "$2" | head -n 1 | sed -E 's/.*value="([^"]*)"/\1/'
}

# ping_stats ALVO N -> "media/max/perda%" em ms
ping_stats() {
    local out loss rtt avg mx
    out=$(ping -c "$2" -i 0.2 -q -W 2 "$1" 2>&1)
    loss=$(grep -oE '[0-9.]+% packet loss' <<< "${out}" | cut -d% -f1)
    rtt=$(grep -oE '= [0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+' <<< "${out}" | tr -d '= ')
    IFS=/ read -r _ avg mx _ <<< "${rtt}"
    printf '%s/%s/%s%%\n' "${avg:--}" "${mx:--}" "${loss:--}"
}

# isql_ms N -> ms por consulta (inclui a ida e volta e o driver ODBC), ou "falha: ..."
isql_ms() {
    local n=$1 t0 t1 out rc i
    command -v isql >/dev/null 2>&1 || { echo "falha: isql ausente (apt install unixodbc)"; return 1; }
    [[ -n ${DSN_NAME} ]] || { echo "falha: perfil sem DSN ODBC"; return 1; }
    t0=$(date +%s%N)
    out=$(for ((i = 0; i < n; i++)); do echo 'SELECT 1'; done | timeout 300 isql -b "${DSN_NAME}" 2>&1)
    rc=$?
    t1=$(date +%s%N)
    if ((rc != 0)) || grep -qE '\[ISQL\]ERROR|\[unixODBC\]|\[MySQL\]' <<< "${out}"; then
        echo "falha: $(grep -m 1 -E 'ERROR|unixODBC|MySQL' <<< "${out}" | cut -c1-160) (credencial do DSN fora do odbc.ini ou ilegivel para $(id -un))"
        return 1
    fi
    awk -v d=$((t1 - t0)) -v n="${n}" 'BEGIN { printf "%.3f\n", d / 1e6 / n }'
}

sec "Sistema"
printf 'host %s, %s vCPU, load %s\n' "$(hostname)" "$(nproc)" "$(cut -d' ' -f1-3 /proc/loadavg)"
kv hostname "$(hostname)"

sec "FreeSWITCH: status"
st=$(fsx status)
printf '%s\n' "${st}" | head -n 8
if [[ ${st} != *"is ready"* ]]; then
    kv erro "fs_cli sem resposta (sudo -n e senha do event socket)"
fi

sofia_xml=$(fsx 'xml_locate configuration configuration name sofia.conf')
prof_xml=$(awk '/<profile[[:space:]][^>]*name="default"/ { p = 1 } p { print } p && /<\/profile>/ { exit }' <<< "${sofia_xml}")
sec "Perfil SIP default (xml_locate sofia.conf)"
if [[ -n ${prof_xml} ]]; then
    grep -E 'name="(manage-presence|odbc-dsn|presence-[a-z-]+|send-presence-on-register|manage-shared-appearance|dbname|inbound-reg-in-new-thread|max-recv-requests-per-second|track-calls|sip-capture)"' \
        <<< "${prof_xml}" | sed -E 's/^[[:space:]]+//' | mask
else
    echo "perfil default nao encontrado no sofia.conf"
fi
presence=$(param_val manage-presence "${prof_xml}")
kv manage_presence "${presence:-(ausente: padrao do FS)}"

switch_xml=$(fsx 'xml_locate configuration configuration name switch.conf')
sec "switch.conf (xml_locate)"
grep -E 'name="(core-db-dsn|core-db-name|core-dbtype|max-db-handles|db-handle-timeout|sessions-per-second|max-sessions|rtp-start-port|rtp-end-port)"' \
    <<< "${switch_xml}" | sed -E 's/^[[:space:]]+//' | mask
core=$(param_val core-db-dsn "${switch_xml}")
[[ -n ${core} ]] && core="odbc" || core="sqlite $(param_val core-db-name "${switch_xml}")"
kv core_db "${core}"

dsn_raw=$(param_val odbc-dsn "${prof_xml}")
if [[ -z ${dsn_raw} || ${dsn_raw} == *'${'* ]]; then
    dsn_raw=$(fsx 'global_getvar dsn' | head -n 1 | tr -d '\r')
fi
[[ ${dsn_raw} == -ERR* || ${dsn_raw} == *"_undef_"* ]] && dsn_raw=""
DSN_NAME="" dsn_server="" driver=""
case ${dsn_raw} in
    "") ;;
    odbc://*) rest=${dsn_raw#odbc://}; DSN_NAME=${rest%%:*} ;;
    *://*) dsn_server=$(grep -ioE 'server=[^;]+' <<< "${dsn_raw}" | head -n 1 | cut -d= -f2) ;;
    *) DSN_NAME=${dsn_raw%%:*} ;;
esac
sec "DSN"
if [[ -n ${dsn_raw} ]]; then
    printf 'dsn: %s\n' "$(mask <<< "${dsn_raw}")"
else
    echo "dsn vazio: perfil SIP em SQLite local"
fi
kv dsn "$(mask <<< "${dsn_raw:-(vazio)}")"

if [[ -n ${DSN_NAME} ]]; then
    ini=/etc/odbc.ini
    sec "odbc.ini: secao [${DSN_NAME}]"
    if [[ -r ${ini} ]]; then
        section=$(awk -v s="[${DSN_NAME}]" 'index(tolower($0), tolower(s)) == 1 { p = 1; print; next } p && /^\[/ { exit } p { print }' "${ini}")
        if [[ -n ${section} ]]; then
            printf '%s\n' "${section}" | mask
            dsn_server=$(awk -F= 'tolower($1) ~ /^[[:space:]]*(server|host)[[:space:]]*$/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<< "${section}")
            driver=$(awk -F= 'tolower($1) ~ /^[[:space:]]*driver[[:space:]]*$/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' <<< "${section}")
        else
            echo "secao [${DSN_NAME}] ausente em ${ini}"
        fi
    else
        echo "${ini} ilegivel para $(id -un)"
    fi
fi
kv dsn_server "${dsn_server:--}"
kv driver "${driver:--}"

sec "Driver ODBC e pacotes"
if command -v odbcinst >/dev/null 2>&1; then
    odbcinst -q -d 2>&1
    [[ -n ${driver} && ${driver} != /* ]] && odbcinst -q -d -n "${driver}" 2>&1 | mask
else
    echo "odbcinst ausente"
fi
dpkg-query -W -f '${Package} ${Version}\n' 2>/dev/null | grep -iE 'odbc|mysql|mariadb|percona'

targets=()
[[ -n ${dsn_server} ]] && targets+=("${dsn_server}")
for h in ${DB_HOSTS}; do [[ ${h} == "${dsn_server}" ]] || targets+=("${h}"); done
# referencia do resumo: o servidor do DSN; sem ele (odbc.ini ilegivel), o primeiro banco
ref=${targets[0]:-}
kv rtt_ref "${ref:--}"
sec "RTT ocioso (ping, ${PING_N} pacotes a 5/s: media/max/perda em ms)"
if [[ -n ${dsn_server} && ! ${dsn_server} =~ ^[0-9.]+$ ]]; then
    printf '%s resolve para: %s\n' "${dsn_server}" "$(getent hosts "${dsn_server}" | awk '{ print $1 }' | tr '\n' ' ')"
fi
i=0
for t in "${targets[@]}"; do
    ping_stats "${t}" "${PING_N}" > "${TMPD}/ping.${i}" &
    i=$((i + 1))
done
wait
i=0
for t in "${targets[@]}"; do
    r=$(cat "${TMPD}/ping.${i}")
    printf '%-24s %s\n' "${t}" "${r}"
    [[ ${t} == "${ref}" ]] && kv rtt_idle "${r}"
    i=$((i + 1))
done

sec "Consulta ODBC ociosa (isql, ${QUERIES} x SELECT 1)"
r=$(isql_ms "${QUERIES}")
printf '%s ms por consulta\n' "${r}"
kv isql_idle "${r}"

if ((LOAD_AT > 0)); then
    now=$(date +%s)
    late=""
    if ((LOAD_AT > now)); then sleep $((LOAD_AT - now)); else late=" (atrasada $((now - LOAD_AT)) s: a medicao ociosa demorou mais)"; fi
    sec "Sob carga, $(date '+%H:%M:%S')${late}"
    calls=$(fsx 'show calls count' | awk '/total/ { print $1 }')
    printf 'chamadas no FS: %s\n' "${calls:--}"
    fsx status | grep -E 'session\(s\)'
    kv calls_load "${calls:--}"
    if [[ -n ${ref} ]]; then
        r=$(ping_stats "${ref}" 50)
        printf 'ping %s (50 pacotes): %s\n' "${ref}" "${r}"
        kv rtt_load "${r}"
    fi
    r=$(isql_ms 500)
    printf 'isql (500 x SELECT 1): %s ms por consulta\n' "${r}"
    kv isql_load "${r}"
    pid=$(pidof freeswitch 2>/dev/null | awk '{ print $1 }')
    if [[ -n ${pid} ]]; then
        echo
        echo "threads do FreeSWITCH com mais CPU (top -H):"
        top -H -b -n 1 -p "${pid}" 2>/dev/null | sed -n '7,22p'
    fi
fi
REMOTE
}

db_script() {
    local first=$1
    printf 'MYSQL_CLI=%q\nWINDOW=%q\nSCHEMA=%q\nFIRST=%q\n' \
        "${CFG[MYSQL_CLI_CMD]}" "${OPT_WINDOW}" "${OPT_SCHEMA}" "${first}"
    remote_common
    cat <<'REMOTE'
read -ra MY <<< "${MYSQL_CLI}"
my() { timeout 60 "${MY[@]}" -N -B -e "$1" 2>&1; }

Q_HOST="SELECT IFNULL(HOST, '(sem-host)'), SUM(COUNT_STAR), SUM(SUM_TIMER_WAIT) FROM performance_schema.events_statements_summary_by_host_by_event_name GROUP BY HOST"
# SCHEMA_NAME entra na chave: o mesmo DIGEST aparece em mais de um schema
Q_DIG="SELECT CONCAT(IFNULL(SCHEMA_NAME, '-'), '|', DIGEST), COUNT_STAR, SUM_TIMER_WAIT, LEFT(DIGEST_TEXT, 110) FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST IS NOT NULL"

sec "Servidor"
out=$(my "SELECT @@hostname, @@version")
printf '%s\n' "${out}"
if [[ ${out} == ERROR* || ${out} == *"command not found"* ]]; then
    kv erro "MYSQL_CLI_CMD falhou: $(head -n 1 <<< "${out}")"
    exit 0
fi
kv hostname "$(cut -f1 <<< "${out}")"
my "SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime', 'Threads_connected', 'Threads_running', 'wsrep_cluster_size', 'wsrep_local_state_comment')"

if ((FIRST)); then
    sec "Presenca e registros por hostname (schema ${SCHEMA})"
    for t in sip_subscriptions sip_dialogs sip_presence sip_registrations; do
        printf '%s:\n' "${t}"
        my "SELECT hostname, COUNT(*) FROM \`${SCHEMA}\`.\`${t}\` GROUP BY hostname ORDER BY 2 DESC" | sed 's/^/  /'
    done
fi

if ((WINDOW == 0)); then
    sec "Instrucoes por host cliente, acumulado desde a partida do MySQL (execucoes, s, ms medio)"
    my "${Q_HOST}" | awk -F'\t' 'NF >= 3 { s = $3 / 1e12; printf "%-30s %12d %10.1f %9.3f\n", $1, $2, s, ($2 > 0 ? s * 1000 / $2 : 0) } NF < 3 { print }' | sort -k3 -nr
    exit 0
fi

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "${TMPD}"' EXIT
my "${Q_HOST}" > "${TMPD}/h1"
my "${Q_DIG}" > "${TMPD}/d1"
if grep -q '^ERROR' "${TMPD}/h1" "${TMPD}/d1"; then
    sec "performance_schema"
    grep -h '^ERROR' "${TMPD}/h1" "${TMPD}/d1" | sort -u
    kv erro "sem acesso ao performance_schema"
    exit 0
fi
t0=$(date '+%H:%M:%S')
sleep "${WINDOW}"
my "${Q_HOST}" > "${TMPD}/h2"
my "${Q_DIG}" > "${TMPD}/d2"
t1=$(date '+%H:%M:%S')

sec "Delta por host cliente, ${t0} -> ${t1} (execucoes, s, ms medio)"
awk -F'\t' 'NR == FNR { n[$1] = $2; t[$1] = $3; next }
    { dn = $2 - n[$1]; dt = ($3 - t[$1]) / 1e12; if (dn > 0) printf "%-30s %12d %10.1f %9.3f\n", $1, dn, dt, dt * 1000 / dn }' \
    "${TMPD}/h1" "${TMPD}/h2" | sort -k3 -nr

sec "Delta por consulta, 30 maiores em tempo (execucoes, s, ms medio, consulta)"
awk -F'\t' 'NR == FNR { n[$1] = $2; t[$1] = $3; next }
    { dn = $2 - n[$1]; dt = ($3 - t[$1]) / 1e12; if (dn > 0) printf "%9d %9.1f %8.2f  %s\n", dn, dt, dt * 1000 / dn, $4 }' \
    "${TMPD}/d1" "${TMPD}/d2" | sort -k2 -nr | head -n 30
REMOTE
}

# run_job ID ENDERECO TIMEOUT SCRIPT -> TMP/ID.out, TMP/ID.err, TMP/ID.rc
run_job() {
    local id=$1 addr=$2 tmo=$3 script=$4 rc=0
    printf '%s\n' "${script}" | timeout "${tmo}" "${SSH_CMD[@]}" -T "${CFG[SSH_USER]}@${addr}" bash -s \
        > "${TMP}/${id}.out" 2> "${TMP}/${id}.err" || rc=$?
    printf '%s\n' "${rc}" > "${TMP}/${id}.rc"
}

kv_get() { awk -F'\t' -v k="@kv $2" '$1 == k { print $2; exit }' "$1" 2>/dev/null; }

# Saida remota em Markdown: "@sec" vira titulo, o resto vai em bloco de texto.
render_raw() {
    awk '
        /^@kv / { next }
        /^@sec / { if (open) print "```"; sub(/^@sec /, ""); printf "\n#### %s\n\n```text\n", $0; open = 1; next }
        { if (!open) { print "```text"; open = 1 } print }
        END { if (open) print "```" }' "$1"
}

cell() { local v=${1:--}; printf '%s' "${v//|//}"; }

write_report() {
    local id addr
    printf '# Diagnostico do teto de CPS por FreeSWITCH\n\n'
    printf -- '- gerado em: %s, no %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(hostname)"
    # shellcheck disable=SC2016
    printf -- '- configuracao: `%s`\n' "${OPT_CONF}"
    printf -- '- FS: %s; bancos: %s\n' "${CFG[FS_HOSTS]}" "${CFG[DB_HOSTS]}"
    printf -- '- ping ocioso: %s pacotes por alvo; isql ocioso: %s consultas\n' "${OPT_PING}" "${OPT_QUERIES}"
    if ((OPT_WINDOW > 0)); then
        printf -- '- janela do performance_schema: %s s a partir de %s\n' "${OPT_WINDOW}" "$(date -d "@${START}" '+%H:%M:%S')"
    else
        printf -- '- janela do performance_schema: nenhuma (so foto acumulada)\n'
    fi
    if ((LOAD_AT > 0)); then
        printf -- '- medicao sob carga: %s s depois do inicio (%s)\n' "${OPT_LOAD}" "$(date -d "@${LOAD_AT}" '+%H:%M:%S')"
    fi

    printf '\n## Resumo dos FS\n\n'
    printf '| FS | hostname | manage-presence | DSN | servidor do DSN | driver | core db | RTT ate | RTT ocioso (media/max/perda, ms) | isql ocioso (ms/consulta) | RTT sob carga | isql sob carga | chamadas sob carga |\n'
    printf '|---|---|---|---|---|---|---|---|---|---|---|---|---|\n'
    for id in "${FS_IDS[@]}"; do
        local f="${TMP}/${id}.out"
        printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "${ADDR[${id}]}" \
            "$(cell "$(kv_get "${f}" hostname)")" "$(cell "$(kv_get "${f}" manage_presence)")" \
            "$(cell "$(kv_get "${f}" dsn)")" "$(cell "$(kv_get "${f}" dsn_server)")" \
            "$(cell "$(kv_get "${f}" driver)")" "$(cell "$(kv_get "${f}" core_db)")" \
            "$(cell "$(kv_get "${f}" rtt_ref)")" \
            "$(cell "$(kv_get "${f}" rtt_idle)")" "$(cell "$(kv_get "${f}" isql_idle)")" \
            "$(cell "$(kv_get "${f}" rtt_load)")" "$(cell "$(kv_get "${f}" isql_load)")" \
            "$(cell "$(kv_get "${f}" calls_load)")"
    done

    cat <<'EOF'

## Leitura

- RTT ou isql (ms por consulta) maior em um FS: cada consulta sincrona do perfil SIP custa mais
  nesse no. Com ~19 consultas de presenca por chamada, alguns decimos de ms a mais ja somam dezenas
  de ms serializados por chamada.
- DSN, servidor, driver ou opcoes do odbc.ini diferentes entre os FS: a diferenca de caminho ate o
  banco explica a assimetria; alinhe com o no saudavel.
- manage-presence true com DSN ODBC: sip_dialogs e sip_subscriptions no PXC a cada chamada. Sem
  linhas de sip_subscriptions em uso, a presenca pode ser desligada (docs/execucao/gargalo-fs.md).
- Delta por host cliente: o host com mais tempo por execucao, para o mesmo tipo de carga, e o que
  espera mais pelo banco.
EOF

    for id in "${FS_IDS[@]}" "${DB_IDS[@]}"; do
        addr=${ADDR[${id}]}
        printf '\n## %s (%s)\n' "${id}" "${addr}"
        if [[ $(cat "${TMP}/${id}.rc") != 0 ]]; then
            printf '\nFalha na execucao remota (codigo %s; 124 = tempo esgotado).\n' "$(cat "${TMP}/${id}.rc")"
        fi
        render_raw "${TMP}/${id}.out"
        if [[ -s ${TMP}/${id}.err ]]; then
            printf '\n#### stderr\n\n```text\n'
            head -n 40 "${TMP}/${id}.err"
            printf '```\n'
        fi
    done
}

main() {
    parse_args "$@"
    local dep
    for dep in ssh timeout awk; do
        command -v "${dep}" >/dev/null 2>&1 || die "${E_DEPS}" "comando ausente: ${dep}"
    done
    load_config "${OPT_CONF}"
    [[ -n ${OPT_SCHEMA} ]] || OPT_SCHEMA=${CFG[FLUX_DB_NAME]}
    [[ ${OPT_SCHEMA} =~ ^[A-Za-z0-9_]+$ ]] || die "${E_USAGE}" "schema invalido: ${OPT_SCHEMA}"
    [[ -n ${CFG[FS_HOSTS]} ]] || die "${E_CONFIG}" "FS_HOSTS vazio na configuracao"
    build_ssh
    load_fs_password

    [[ -n ${OPT_OUT} ]] || OPT_OUT="${PWD}/diag-fs-$(date +%Y%m%d-%H%M%S).md"
    [[ -e ${OPT_OUT} ]] && die "${E_USAGE}" "arquivo de saida ja existe: ${OPT_OUT}"
    [[ -w $(dirname "${OPT_OUT}") ]] || die "${E_USAGE}" "sem permissao para gravar em $(dirname "${OPT_OUT}")"

    TMP=$(mktemp -d)
    trap 'rm -rf "${TMP}"' EXIT

    START=$(date +%s)
    LOAD_AT=0
    ((OPT_LOAD > 0)) && LOAD_AT=$((START + OPT_LOAD))
    local longest=$((OPT_WINDOW > OPT_LOAD ? OPT_WINDOW : OPT_LOAD))

    declare -gA ADDR=()
    FS_IDS=() DB_IDS=()
    local -a list pids=()
    local h i=0 id script fs_tmo db_tmo
    fs_tmo=$((OPT_PING / 5 + OPT_QUERIES / 20 + 240 + OPT_LOAD))
    db_tmo=$((180 + OPT_WINDOW))
    script=$(fs_script)
    read -ra list <<< "${CFG[FS_HOSTS]}"
    for h in "${list[@]}"; do
        [[ ${h} =~ ^[A-Za-z0-9._:-]+$ ]] || die "${E_CONFIG}" "endereco invalido em FS_HOSTS: '${h}'"
        i=$((i + 1)); id="fs${i}"; FS_IDS+=("${id}"); ADDR[${id}]=${h}
        run_job "${id}" "${h}" "${fs_tmo}" "${script}" &
        pids+=($!)
    done
    i=0
    read -ra list <<< "${CFG[DB_HOSTS]}"
    for h in "${list[@]}"; do
        [[ ${h} =~ ^[A-Za-z0-9._:-]+$ ]] || die "${E_CONFIG}" "endereco invalido em DB_HOSTS: '${h}'"
        i=$((i + 1)); id="db${i}"; DB_IDS+=("${id}"); ADDR[${id}]=${h}
        run_job "${id}" "${h}" "${db_tmo}" "$(db_script $((i == 1)))" &
        pids+=($!)
    done

    log "coletando de ${#FS_IDS[@]} FS e ${#DB_IDS[@]} banco(s); duracao estimada ate $((OPT_PING / 5 + longest + 60)) s"
    ((OPT_WINDOW > 0 || OPT_LOAD > 0)) && log "dispare a escada agora; medicao sob carga em ${OPT_LOAD} s, janela de ${OPT_WINDOW} s"
    wait "${pids[@]}" || true

    write_report > "${OPT_OUT}"

    local failed=0
    for id in "${FS_IDS[@]}" "${DB_IDS[@]}"; do
        if [[ $(cat "${TMP}/${id}.rc") != 0 ]]; then
            warn "${id} (${ADDR[${id}]}): execucao remota falhou (codigo $(cat "${TMP}/${id}.rc"))"
            failed=1
        elif grep -q $'^@kv erro\t' "${TMP}/${id}.out"; then
            warn "${id} (${ADDR[${id}]}): $(kv_get "${TMP}/${id}.out" erro)"
        fi
    done
    log "resultado: ${OPT_OUT}"
    ((failed == 0)) || exit "${E_REMOTE}"
}

main "$@"
