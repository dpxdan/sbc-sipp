#!/usr/bin/env bash
#
# capacidade.sh - foto de capacidade de um servidor para o flux-loadtest (WEB-1437)
#
# Enviado pela VM de teste e executado no servidor sem instalacao, como o collector.sh:
#   ssh host "nice -n 10 bash -s -- --role fs --cmd 'sudo -n fs_cli -x' --disk /var/lib/freeswitch" < capacidade.sh
#
# Somente leitura: /proc, /sys, df, ss, systemctl show e os comandos de status do servico
# (fs_cli, opensips-cli, mysql). Nao grava nada no servidor.
#
# Saida: uma linha "chave=valor" por metrica (valores sem espaco; vazio = nao coletado).
# Convencoes: *_pct percentual de uso do limite; *_mb megabytes; *_s segundos.
# Nunca imprime senha ou DSN: do core-db-dsn sai so o tipo (odbc).
#
# Daniel Paixão – Flux Telecom 2026

set -uo pipefail
export LC_ALL=C

ROLE=gen
DISK_PATH=/
APP_CMD=""
CMD_TIMEOUT=10

die() { printf 'capacidade: %s\n' "$*" >&2; exit 2; }

while (($# > 0)); do
    case "$1" in
        --role) ROLE="${2:-}"; shift 2 ;;
        --disk) DISK_PATH="${2:-}"; shift 2 ;;
        --cmd)  APP_CMD="${2:-}"; shift 2 ;;
        *) die "opcao invalida: $1" ;;
    esac
done
case "${ROLE}" in
    fs|opensips|db|web|gen) ;;
    *) die "--role invalido: ${ROLE}" ;;
esac

APP=()
if [[ -n ${APP_CMD} ]]; then
    read -ra APP <<< "${APP_CMD}"
fi

# Senha do fs_cli: 1a linha do stdin (FS_CLI_PASSWORD=...), inserida apos a palavra fs_cli.
FS_CLI_PASSWORD=${FS_CLI_PASSWORD:-}
if [[ ${ROLE} == fs && -n ${FS_CLI_PASSWORD} ]]; then
    fs_cmd=()
    fs_added=0
    for w in "${APP[@]}"; do
        fs_cmd+=("${w}")
        if ((fs_added == 0)) && [[ ${w##*/} == fs_cli ]]; then
            fs_cmd+=(-p "${FS_CLI_PASSWORD}")
            fs_added=1
        fi
    done
    ((fs_added)) || die "--cmd sem fs_cli: senha do fs_cli nao aplicada"
    APP=("${fs_cmd[@]}")
    unset fs_cmd fs_added w
fi

# ---------------------------------------------------------------- utilitarios
# kv CHAVE VALOR: imprime so se houver valor; espacos viram "_"
kv() {
    local k=$1 v=${2-}
    v=${v//$'\r'/}
    v=${v//$'\n'/ }
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    v=${v//[[:space:]]/_}
    [[ -n ${v} ]] && printf '%s=%s\n' "${k}" "${v}"
    return 0
}

is_num() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# pct USO LIMITE -> percentual com 1 casa (vazio se faltar dado ou limite 0)
pct() {
    is_num "${1:-}" && is_num "${2:-}" && (($2 > 0)) || return 0
    awk -v u="$1" -v l="$2" 'BEGIN { printf "%.1f", u * 100 / l }'
}

run_app() {
    ((${#APP[@]} > 0)) || return 1
    timeout "${CMD_TIMEOUT}" "${APP[@]}" "$@" 2>/dev/null
}

json_num() {
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*-\?[0-9]\+" | head -1 | grep -o -- '-\?[0-9]\+$'
}

# menor valor numerico entre os argumentos (ignora vazio, "infinity", "unlimited")
min_num() {
    local m="" x
    for x in "$@"; do
        is_num "${x}" || continue
        if [[ -z ${m} ]] || ((x < m)); then m=${x}; fi
    done
    printf '%s' "${m}"
}

# ---------------------------------------------------------------- sistema
system_info() {
    local up threads tmax
    kv sys_host "$(uname -n)"
    kv sys_cpus "$(nproc 2>/dev/null)"
    read -r up _ < /proc/uptime
    kv sys_uptime_s "${up%.*}"
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
         END {
             if (t > 0) printf "sys_mem_total_mb=%d\nsys_mem_avail_mb=%d\nsys_mem_avail_pct=%.1f\n", t / 1024, a / 1024, a * 100 / t
             printf "sys_swap_used_mb=%d\n", (st - sf) / 1024
         }' /proc/meminfo
    threads=$(awk '{ split($4, a, "/"); print a[2] }' /proc/loadavg)
    tmax=$(cat /proc/sys/kernel/threads-max 2>/dev/null)
    kv sys_threads "${threads}"
    kv sys_threads_max "${tmax}"
    kv sys_threads_pct "$(pct "${threads}" "${tmax}")"
    kv sys_pid_max "$(cat /proc/sys/kernel/pid_max 2>/dev/null)"
    kv sys_load1 "$(awk '{ print $1 }' /proc/loadavg)"
    kv sys_udp_rcvbuf_errors "$(awk '/^Udp:/ { if (!h) { for (i = 1; i <= NF; i++) k[i] = $i; h = 1; next }
                                               for (i = 1; i <= NF; i++) if (k[i] == "RcvbufErrors") print $i }' /proc/net/snmp)"
    kv sys_rmem_max "$(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
    if [[ -n ${DISK_PATH} ]]; then
        kv sys_disk_path "${DISK_PATH}"
        kv sys_disk_free_pct "$(df -P "${DISK_PATH}" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print 100 - $5 }')"
        kv sys_disk_free_mb "$(df -Pm "${DISK_PATH}" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    fi
}

# ---------------------------------------------------------------- processo
# proc_info PREFIXO PID UNIDADE_SYSTEMD
# Threads, RSS e limites do processo; LimitNPROC, TasksMax e threads-max dao o teto de threads.
proc_info() {
    local p=$1 pid=$2 unit=$3 thr rss nproc nofile fds up start age tasks_max tasks_cur lim line
    [[ -n ${pid} && -r /proc/${pid}/status ]] || { kv "${p}_running" nao; return 0; }
    kv "${p}_running" sim
    kv "${p}_pid" "${pid}"
    thr=$(awk '/^Threads:/ { print $2 }' "/proc/${pid}/status")
    rss=$(awk '/^VmRSS:/ { print int($2 / 1024) }' "/proc/${pid}/status")
    kv "${p}_threads" "${thr}"
    kv "${p}_rss_mb" "${rss}"
    # /proc/PID/limits e legivel por qualquer usuario; soft limit
    nproc=$(awk '/^Max processes/ { print $3 }' "/proc/${pid}/limits" 2>/dev/null)
    nofile=$(awk '/^Max open files/ { print $4 }' "/proc/${pid}/limits" 2>/dev/null)
    kv "${p}_limit_nproc" "${nproc}"
    kv "${p}_limit_nofile" "${nofile}"
    # /proc/PID/fd exige ser o dono ou root: sem permissao, a metrica fica vazia
    if [[ -r /proc/${pid}/fd ]] && ls -U "/proc/${pid}/fd" >/dev/null 2>&1; then
        fds=$(find "/proc/${pid}/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        kv "${p}_fds" "${fds}"
        kv "${p}_fds_pct" "$(pct "${fds}" "${nofile}")"
    fi
    read -r up _ < /proc/uptime
    start=$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/${pid}/stat" 2>/dev/null)
    if is_num "${start}"; then
        age=$(( ${up%.*} - start / $(getconf CLK_TCK 2>/dev/null || echo 100) ))
        kv "${p}_uptime_s" "${age}"
    fi
    if [[ -n ${unit} ]] && command -v systemctl >/dev/null 2>&1; then
        while IFS='=' read -r line lim; do
            case "${line}" in
                TasksMax)     tasks_max=${lim} ;;
                TasksCurrent) tasks_cur=${lim} ;;
            esac
        done < <(systemctl show -p TasksMax -p TasksCurrent "${unit}" 2>/dev/null)
        kv "${p}_tasks_max" "${tasks_max:-}"
        kv "${p}_tasks_current" "${tasks_cur:-}"
    fi
    lim=$(min_num "${nproc}" "${tasks_max:-}" "$(cat /proc/sys/kernel/threads-max 2>/dev/null)")
    kv "${p}_threads_limit" "${lim}"
    kv "${p}_threads_pct" "$(pct "${thr}" "${lim}")"
}

first_pid() {
    local pid
    pid=$(pidof -s "$1" 2>/dev/null) || pid=$(pgrep -xo "$1" 2>/dev/null) || true
    printf '%s' "${pid}"
}

# ---------------------------------------------------------------- FreeSWITCH
# xml_param XML NOME: valor do <param name="NOME" value="..."/> (primeira ocorrencia)
xml_param() {
    printf '%s' "$1" | tr '>' '\n' \
        | sed -n "s/.*<param[[:space:]][^<]*name=\"$2\"[^<]*value=\"\([^\"]*\)\".*/\1/p" | head -n 1
}

fs_info() {
    local st out sw sofia max sps cfg_max cfg_sps now_s peak calls lvl start end used dbdir logdir age mt
    proc_info fs "$(first_pid freeswitch)" freeswitch.service

    st=$(run_app status) || { kv fs_cli falha; return 0; }
    kv fs_cli ok
    max=$(run_app "fsctl max_sessions" | grep -oE '[0-9]+' | tail -n 1)
    sps=$(run_app "fsctl sps" | grep -oE '[0-9]+' | tail -n 1)
    now_s=$(printf '%s\n' "${st}" | awk '/session\(s\) - peak/ { print $1; exit }')
    peak=$(printf '%s\n' "${st}" | awk '/session\(s\) - peak/ { for (i = 1; i <= NF; i++) if ($i == "peak") { gsub(",", "", $(i + 1)); print $(i + 1); exit } }')
    calls=$(run_app "show calls count" | grep -o '^[0-9]\+ total' | grep -o '^[0-9]\+')
    kv fs_max_sessions "${max}"
    kv fs_sps "${sps}"
    kv fs_sessions "${now_s}"
    kv fs_sessions_peak "${peak}"
    kv fs_sessions_pct "$(pct "${now_s}" "${max}")"
    kv fs_calls "${calls}"
    lvl=$(run_app "fsctl loglevel" | grep -oE '\[[0-9]+\]' | tr -d '[]')
    kv fs_loglevel "${lvl}"

    # Configuracao vista pelo FS (arquivo ou xml_curl). Vale no restart; compare com os valores em uso.
    sw=$(run_app "xml_locate configuration configuration name switch.conf")
    cfg_max=$(xml_param "${sw}" max-sessions)
    cfg_sps=$(xml_param "${sw}" sessions-per-second)
    kv fs_cfg_max_sessions "${cfg_max}"
    kv fs_cfg_sps "${cfg_sps}"
    kv fs_cfg_max_db_handles "$(xml_param "${sw}" max-db-handles)"
    kv fs_cfg_db_handle_timeout "$(xml_param "${sw}" db-handle-timeout)"
    if [[ -n $(xml_param "${sw}" core-db-dsn) ]]; then
        kv fs_cfg_core_db odbc
    else
        kv fs_cfg_core_db sqlite
    fi

    # Portas RTP: faixa do switch.conf (padrao do FS 16384-32768) e sockets UDP na faixa
    start=$(xml_param "${sw}" rtp-start-port)
    end=$(xml_param "${sw}" rtp-end-port)
    is_num "${start}" || start=16384
    is_num "${end}" || end=32768
    used=$(ss -Huan 2>/dev/null | awk -v s="${start}" -v e="${end}" '
        { n = split($4, a, ":"); p = a[n] + 0; if (p >= s && p <= e) c++ } END { print c + 0 }')
    kv fs_rtp_port_start "${start}"
    kv fs_rtp_port_end "${end}"
    kv fs_rtp_ports_total "$((end - start + 1))"
    kv fs_rtp_ports_used "${used}"
    kv fs_rtp_ports_pct "$(pct "${used}" "$((end - start + 1))")"

    # Timeout de midia: parametros dos profiles Sofia (s) e variaveis globais (ms).
    # O media_timeout definido no dialplan ou no Lua nao aparece aqui.
    sofia=$(run_app "xml_locate configuration configuration name sofia.conf")
    printf '%s' "${sofia}" | tr '>' '\n' | awk '
        /<profile[[:space:]]/ { p = ""; if (match($0, /name="[^"]*"/)) { p = tolower(substr($0, RSTART + 6, RLENGTH - 7)); gsub(/[^a-z0-9_]/, "_", p) } }
        /<\/profile/ { p = "" }
        /<gateway[[:space:]]/ { g = 1 } /<\/gateway/ { g = 0 }
        p != "" && !g && /<param[[:space:]]/ {
            n = ""; v = ""
            if (match($0, /name="[^"]*"/)) n = substr($0, RSTART + 6, RLENGTH - 7)
            if (match($0, /value="[^"]*"/)) v = substr($0, RSTART + 7, RLENGTH - 8)
            if ((n == "rtp-timeout-sec" || n == "rtp-hold-timeout-sec") && v != "") {
                gsub(/-/, "_", n); printf "fs_profile_%s_%s=%s\n", p, n, v
            }
        }'
    out=$(run_app "global_getvar media_timeout")
    is_num "${out}" && kv fs_global_media_timeout_ms "${out}"
    out=$(run_app "global_getvar media_hold_timeout")
    is_num "${out}" && kv fs_global_media_hold_timeout_ms "${out}"

    # core.db: se o switch.conf aponta para ODBC e o arquivo SQLite continua sendo escrito,
    # o processo ainda usa a configuracao anterior (restart pendente)
    dbdir=$(run_app "global_getvar db_dir")
    if [[ -n ${dbdir} && -f ${dbdir}/core.db ]]; then
        mt=$(stat -c %Y "${dbdir}/core.db" 2>/dev/null)
        if is_num "${mt}"; then
            age=$(( $(date +%s) - mt ))
            kv fs_core_db_file_age_s "${age}"
        fi
    fi
    logdir=$(run_app "global_getvar log_dir")
    if [[ -n ${logdir} && -d ${logdir} ]]; then
        kv fs_log_disk_free_pct "$(df -P "${logdir}" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print 100 - $5 }')"
        kv fs_log_size_mb "$(du -sm "${logdir}" 2>/dev/null | awk '{ print $1 }')"
    fi
}

# ---------------------------------------------------------------- OpenSIPS
os_info() {
    local st k tot ru mu lb
    kv os_procs "$(pgrep -cx opensips 2>/dev/null)"
    proc_info os_main "$(first_pid opensips)" opensips.service
    st=$(run_app get_statistics shmem: dialog: tm: load: core:) || { kv os_mi falha; return 0; }
    kv os_mi ok
    for k in total_size used_size real_used_size max_used_size free_size fragments; do
        kv "os_shm_${k}" "$(json_num "${st}" "shmem:${k}")"
    done
    tot=$(json_num "${st}" 'shmem:total_size')
    ru=$(json_num "${st}" 'shmem:real_used_size')
    mu=$(json_num "${st}" 'shmem:max_used_size')
    is_num "${tot}" && kv os_shm_total_mb "$((tot / 1048576))"
    kv os_shm_real_used_pct "$(pct "${ru}" "${tot}")"
    kv os_shm_max_used_pct "$(pct "${mu}" "${tot}")"
    for k in active_dialogs early_dialogs processed_dialogs failed_dialogs expired_dialogs; do
        kv "os_dlg_${k%_dialogs}" "$(json_num "${st}" "dialog:${k}")"
    done
    kv os_tm_inuse "$(json_num "${st}" 'tm:inuse_transactions')"
    kv os_load "$(json_num "${st}" 'load:load')"
    kv os_drop_requests "$(json_num "${st}" 'core:drop_requests')"

    # load_balancer: max e load de cada recurso por destino
    lb=$(run_app lb_list) || return 0
    command -v python3 >/dev/null 2>&1 || { kv os_lb parse_sem_python3; return 0; }
    printf '%s' "${lb}" | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("os_lb=json_invalido"); sys.exit(0)
dests = data.get("Destinations", data if isinstance(data, list) else [])
for i, d in enumerate(dests, 1):
    p = "os_lb_%d" % i
    print("%s_uri=%s" % (p, str(d.get("uri", "")).replace(" ", "_")))
    print("%s_group=%s" % (p, d.get("group", "")))
    print("%s_enabled=%s" % (p, d.get("enabled", "")))
    for r in d.get("Resources", []):
        n = re.sub(r"[^a-z0-9_]", "_", str(r.get("name", "")).lower())
        mx, ld = r.get("max"), r.get("load")
        print("%s_%s_max=%s" % (p, n, mx))
        print("%s_%s_load=%s" % (p, n, ld))
        if isinstance(mx, int) and isinstance(ld, int) and mx > 0:
            print("%s_%s_pct=%.1f" % (p, n, ld * 100.0 / mx))
'
}

# ---------------------------------------------------------------- MySQL / PXC
db_info() {
    local name val
    local -A s=()
    proc_info db "$(first_pid mysqld)" mysql.service
    while IFS=$'\t' read -r name val; do
        [[ -n ${name} ]] && s[${name}]=${val}
    done < <(run_app -N -B -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections','wsrep_cluster_size','wsrep_local_state_comment','wsrep_flow_control_paused','wsrep_local_recv_queue_max','wsrep_local_send_queue_max','wsrep_cert_deps_distance')"
             run_app -N -B -e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('max_connections','pxc_strict_mode','wsrep_applier_threads','wsrep_slave_threads','innodb_buffer_pool_size')")
    ((${#s[@]} > 0)) || { kv db_cli falha; return 0; }
    kv db_cli ok
    kv db_threads_connected "${s[Threads_connected]:-}"
    kv db_threads_running "${s[Threads_running]:-}"
    kv db_max_used_connections "${s[Max_used_connections]:-}"
    kv db_max_connections "${s[max_connections]:-}"
    kv db_conn_pct "$(pct "${s[Threads_connected]:-}" "${s[max_connections]:-}")"
    kv db_max_used_conn_pct "$(pct "${s[Max_used_connections]:-}" "${s[max_connections]:-}")"
    kv db_buffer_pool_mb "$(is_num "${s[innodb_buffer_pool_size]:-}" && printf '%s' "$((s[innodb_buffer_pool_size] / 1048576))")"
    kv db_pxc_strict_mode "${s[pxc_strict_mode]:-}"
    kv db_wsrep_applier_threads "${s[wsrep_applier_threads]:-${s[wsrep_slave_threads]:-}}"
    kv db_wsrep_cluster_size "${s[wsrep_cluster_size]:-}"
    kv db_wsrep_state "${s[wsrep_local_state_comment]:-}"
    kv db_wsrep_flow_control_paused "${s[wsrep_flow_control_paused]:-}"
    kv db_wsrep_recv_queue_max "${s[wsrep_local_recv_queue_max]:-}"
    kv db_wsrep_send_queue_max "${s[wsrep_local_send_queue_max]:-}"
}

# ---------------------------------------------------------------- principal
kv cap_role "${ROLE}"
kv cap_ts "$(date +%s)"
system_info
case "${ROLE}" in
    fs)       fs_info ;;
    opensips) os_info ;;
    db)       db_info ;;
    web)      proc_info web_nginx "$(first_pid nginx)" nginx.service ;;
    gen)      kv gen_nofile_soft "$(ulimit -Sn)"; kv gen_nofile_hard "$(ulimit -Hn)"
              proc_info gen_sipp "$(first_pid sipp)" "" ;;
esac
exit 0
