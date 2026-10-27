#!/usr/bin/env bash
#
# collector.sh - coletor de metricas do flux-loadtest (WEB-1437)
#
# Enviado pela VM de teste e executado no servidor sem instalacao:
#   ssh host "nice -n 10 bash -s -- --role fs --interval 5 ..." < collector.sh
#
# Somente leitura: /proc, df e os comandos de status configurados. Nao grava
# nada no servidor. Escreve CSV em stdout (1a linha = cabecalho) e encerra
# sozinho apos --max segundos ou quando o SSH cai (SIGPIPE na escrita).
#
# Convencoes das colunas:
#   *_pct    percentual (cpu: 100 = 1 nucleo nas colunas de processo)
#   *_s      taxa por segundo no intervalo
#   *_total  contador acumulado do servico (o relatorio usa a diferenca)

set -uo pipefail
export LC_ALL=C

INTERVAL=5
MAX_SECONDS=3600
ROLE=gen
DISK_PATH=/
PROCS=""
APP_CMD=""
NGINX_URL=""
FPM_URL=""
DB_VIP=""
CMD_TIMEOUT=4

die() { printf 'collector: %s\n' "$*" >&2; exit 2; }

while (($# > 0)); do
    case "$1" in
        --interval)  INTERVAL="${2:-}"; shift 2 ;;
        --max)       MAX_SECONDS="${2:-}"; shift 2 ;;
        --role)      ROLE="${2:-}"; shift 2 ;;
        --disk)      DISK_PATH="${2:-}"; shift 2 ;;
        --procs)     PROCS="${2:-}"; shift 2 ;;
        --cmd)       APP_CMD="${2:-}"; shift 2 ;;
        --nginx-url) NGINX_URL="${2:-}"; shift 2 ;;
        --fpm-url)   FPM_URL="${2:-}"; shift 2 ;;
        --vip)       DB_VIP="${2:-}"; shift 2 ;;
        *) die "opcao invalida: $1" ;;
    esac
done

[[ ${INTERVAL} =~ ^[0-9]+$ ]] && ((INTERVAL >= 1)) || die "--interval invalido: ${INTERVAL}"
[[ ${MAX_SECONDS} =~ ^[0-9]+$ ]] || die "--max invalido: ${MAX_SECONDS}"
[[ -z ${DB_VIP} || ${DB_VIP} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--vip invalido: ${DB_VIP}"
case "${ROLE}" in
    fs|opensips|db|web|gen) ;;
    *) die "--role invalido: ${ROLE}" ;;
esac
((BASH_VERSINFO[0] >= 5)) || die "bash 5 ou superior necessario (EPOCHREALTIME)"

CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
PAGE_KB=$(( $(getconf PAGESIZE 2>/dev/null || echo 4096) / 1024 ))
IFS=',' read -ra PROC_LIST <<< "${PROCS}"
APP=()
if [[ -n ${APP_CMD} ]]; then
    read -ra APP <<< "${APP_CMD}"
fi

# Senha do fs_cli: definida pelo flux-loadtest.sh como 1a linha do stdin (bash -s),
# nunca por argumento. Inserida logo apos a palavra fs_cli de --cmd.
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

# Formata inteiro escalado por 10 ou 100 como decimal (sem depender de locale).
fmt1() {
    local v=$1 s=""
    if ((v < 0)); then s="-"; v=$((-v)); fi
    printf '%s%d.%d' "${s}" $((v / 10)) $((v % 10))
}
fmt2() {
    local v=$1 s=""
    if ((v < 0)); then s="-"; v=$((-v)); fi
    printf '%s%d.%02d' "${s}" $((v / 100)) $((v % 100))
}

# Taxa por segundo de um delta, com o intervalo real em milissegundos.
rate() {
    local delta=$1
    ((DT_MS > 0)) || { printf ''; return; }
    ((delta < 0)) && delta=0
    printf '%d' $((delta * 1000 / DT_MS))
}

now_us() {
    local t=${EPOCHREALTIME}
    printf '%s' "${t/./}"
}

# ---------------------------------------------------------------- CPU
declare -A CT=() CI=() CW=() CS=() CST=() PCT=() PCI=() PCW=() PCS=() PCST=()

read_cpu() {
    local name u n s i w irq sirq st rest
    CT=() CI=() CW=() CS=() CST=()
    while read -r name u n s i w irq sirq st rest; do
        [[ ${name} == cpu* ]] || break
        CT[${name}]=$((u + n + s + i + w + irq + sirq + st))
        CI[${name}]=$((i + w))
        CW[${name}]=${w}
        CS[${name}]=${sirq}
        CST[${name}]=${st}
    done < /proc/stat
}

save_cpu() {
    local k
    PCT=() PCI=() PCW=() PCS=() PCST=()
    for k in "${!CT[@]}"; do
        PCT[${k}]=${CT[${k}]}
        PCI[${k}]=${CI[${k}]}
        PCW[${k}]=${CW[${k}]}
        PCS[${k}]=${CS[${k}]}
        PCST[${k}]=${CST[${k}]}
    done
}

# ---------------------------------------------------------------- rede
NET_RB=0 NET_RP=0 NET_TB=0 NET_TP=0 NET_RD=0 NET_TD=0
read_net() {
    # /proc/net/dev: recepcao bytes(2) pacotes(3) erros(4) descartes(5); envio bytes(10) pacotes(11) descartes(13)
    read -r NET_RB NET_RP NET_TB NET_TP NET_RD NET_TD < <(awk 'NR > 2 {
            sub(/:/, " ")
            if ($1 != "lo") { rb += $2; rp += $3; tb += $10; tp += $11; rd += $5; td += $13 }
        } END { printf "%d %d %d %d %d %d\n", rb, rp, tb, tp, rd, td }' /proc/net/dev)
}

UDP_ERR=0 UDP_RCVBUF=0
read_udp() {
    read -r UDP_ERR UDP_RCVBUF < <(awk '/^Udp:/ {
            if (!h) { for (i = 2; i <= NF; i++) k[i] = $i; h = 1; next }
            for (i = 2; i <= NF; i++) {
                if (k[i] == "InErrors") e = $i
                if (k[i] == "RcvbufErrors") r = $i
            }
        } END { printf "%d %d\n", e, r }' /proc/net/snmp)
}

# ---------------------------------------------------------------- disco
DISKS=""
for d in /sys/block/*; do
    d=${d##*/}
    case "${d}" in
        loop*|ram*|sr*|dm-*|zram*|md*|fd*) continue ;;
    esac
    DISKS+="${d} "
done

declare -A DRD=() DWR=() DTK=() PDRD=() PDWR=() PDTK=()
read_disk() {
    local name rd wr tk
    DRD=() DWR=() DTK=()
    while read -r name rd wr tk; do
        DRD[${name}]=${rd}
        DWR[${name}]=${wr}
        DTK[${name}]=${tk}
    done < <(awk -v list=" ${DISKS}" 'index(list, " " $3 " ") { print $3, $6, $10, $13 }' /proc/diskstats)
}

disk_free_pct() {
    df -P "${DISK_PATH}" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print 100 - $5 }'
}

# ---------------------------------------------------------------- processos
declare -A PTK=() PPTK=() G_CPU=() G_RSS=() G_THR=() G_PIDS=()
declare -A TTK=() PTTK=() G_MAXT=()
UPTIME_TICKS=0
PREV_UPTIME_TICKS=0

read_uptime_ticks() {
    local up
    read -r up _ < /proc/uptime
    UPTIME_TICKS=$(( ${up%.*} * CLK_TCK ))
}

proc_group_name() {
    local g=${1//[^a-zA-Z0-9]/_}
    printf '%s' "${g,,}"
}

sample_procs() {
    local d comm stat rest g gname pid ticks start delta
    local -a f
    PTK=()
    G_CPU=() G_RSS=() G_THR=() G_PIDS=()
    for g in "${PROC_LIST[@]}"; do
        gname=$(proc_group_name "${g}")
        G_CPU[${gname}]=0
        G_RSS[${gname}]=0
        G_THR[${gname}]=0
        G_PIDS[${gname}]=""
    done
    ((${#PROC_LIST[@]} > 0)) || return 0

    for d in /proc/[0-9]*; do
        { read -r comm < "${d}/comm"; } 2>/dev/null || continue
        for g in "${PROC_LIST[@]}"; do
            # nome exato ou nome + versao (php-fpm7.3); evita mysqld_safe, opensips-cli etc.
            [[ ${comm} == "${g}" || ${comm} == "${g}"[0-9]* ]] || continue
            { read -r stat < "${d}/stat"; } 2>/dev/null || break
            rest=${stat##*) }
            read -ra f <<< "${rest}"
            # f[0] = campo 3 (state); utime=14 stime=15 threads=20 start=22 rss=24
            pid=${d##*/}
            ticks=$((f[11] + f[12]))
            start=${f[19]}
            PTK[${pid}]=${ticks}
            if [[ -n ${PPTK[${pid}]+x} ]]; then
                delta=$((ticks - PPTK[${pid}]))
            elif ((PREV_UPTIME_TICKS > 0 && start >= PREV_UPTIME_TICKS)); then
                delta=${ticks}
            else
                delta=0
            fi
            ((delta < 0)) && delta=0
            gname=$(proc_group_name "${g}")
            G_CPU[${gname}]=$((G_CPU[${gname}] + delta))
            G_RSS[${gname}]=$((G_RSS[${gname}] + f[21] * PAGE_KB))
            G_THR[${gname}]=$((G_THR[${gname}] + f[17]))
            G_PIDS[${gname}]+="${pid} "
            break
        done
    done
}

save_procs() {
    local k
    PPTK=()
    for k in "${!PTK[@]}"; do
        PPTK[${k}]=${PTK[${k}]}
    done
}

# Thread mais carregada de cada grupo (ticks no intervalo, em G_MAXT). Mostra o gargalo de uma
# thread so (loop do sofia-sip, um worker do OpenSIPS, o SIPp) que a CPU total do processo esconde.
# O cat ignora threads que terminam entre o glob e a leitura; /proc/PID/task/TID/stat e legivel
# por qualquer usuario. Thread nova no intervalo conta a partir da proxima amostra.
sample_threads() {
    local gname pid tid ticks d max
    local -a files
    TTK=() G_MAXT=()
    for gname in "${!G_PIDS[@]}"; do
        max=0
        files=()
        for pid in ${G_PIDS[${gname}]}; do
            files+=("/proc/${pid}/task/"*/stat)
        done
        if ((${#files[@]} > 0)); then
            while read -r tid ticks; do
                [[ -n ${ticks} ]] || continue
                TTK[${tid}]=${ticks}
                if [[ -n ${PTTK[${tid}]+x} ]]; then
                    d=$((ticks - PTTK[${tid}]))
                    ((d > max)) && max=${d}
                fi
            done < <(cat "${files[@]}" 2>/dev/null | awk '{ t = $1; sub(/^.*\) /, ""); print t, $12 + $13 }')
        fi
        G_MAXT[${gname}]=${max}
    done
    PTTK=()
    for tid in "${!TTK[@]}"; do
        PTTK[${tid}]=${TTK[${tid}]}
    done
}

# ms desde um instante de now_us
ms_since() { printf '%d' $(( ($(now_us) - $1) / 1000 )); }

# ---------------------------------------------------------------- servicos
run_app() {
    ((${#APP[@]} > 0)) || return 1
    timeout "${CMD_TIMEOUT}" "${APP[@]}" "$@" 2>/dev/null
}

json_num() {
    # Extrai "chave": numero de um JSON simples (opensips-cli, php-fpm).
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*-\?[0-9]\+" | head -1 | grep -o -- '-\?[0-9]\+$'
}

declare -A APREV=()

# Taxa de contador acumulado entre amostras, em CR; vazio na primeira.
# Nao chamar dentro de $(...): o estado em APREV precisa persistir.
counter_rate() {
    local key=$1 val=$2
    CR=""
    if [[ -n ${val} && -n ${APREV[${key}]:-} ]]; then
        CR=$(rate $((val - APREV[${key}])))
    fi
    if [[ -n ${val} ]]; then
        APREV[${key}]=${val}
    fi
}

app_header() {
    case "${ROLE}" in
        fs)       printf ',fs_calls,fs_sessions,fs_sps,fs_idle_cpu,fs_api_ms,fs_db_probe_ms,fs_max_sessions,fs_sessions_pct'
                  printf ',fs_db_handles,fs_db_handles_used,fs_db_handles_pct' ;;
        opensips) printf ',os_active_dlg,os_early_dlg,os_tm_inuse,os_rcv_req_s,os_failed_dlg_total,os_drop_req_total,os_shm_used_pct,os_load,os_lb_max_pct' ;;
        db)       printf ',db_qps,db_select_s,db_insert_s,db_update_s,db_threads_running,db_threads_connected,db_slow_total,db_row_lock_waits_total,db_repl_lag,db_repl_ok'
                  printf ',db_wsrep_recv_queue,db_wsrep_send_queue,db_wsrep_fc_paused_pct,db_wsrep_cluster_size,db_wsrep_state,db_wsrep_primary,db_vip'
                  printf ',db_stmt_avg_ms,db_conn_pct' ;;
        web)      printf ',ngx_active,ngx_rps,ngx_writing,ngx_waiting,fpm_active,fpm_idle,fpm_listen_queue,fpm_rps,fpm_max_children_total,fpm_slow_total' ;;
        gen)      printf '' ;;
    esac
}

# Resultado em APP_LINE. Nao chamar dentro de $(...) (ver counter_rate).
app_sample() {
    local out calls sessions sps idle
    APP_LINE=""
    case "${ROLE}" in
    fs)
        # Tempos de resposta do FS (inclui ~10-30 ms do fs_cli; teto em CMD_TIMEOUT):
        #   status            nucleo e event socket, sem banco
        #   show calls count  consulta o banco interno (core db): sobe quando faltam handles
        #                     (max-db-handles/db-handle-timeout) ou o banco do core esta lento
        local t0 api_ms db_ms
        t0=$(now_us)
        out=$(run_app "show calls count")
        db_ms=$(ms_since "${t0}")
        calls=$(printf '%s' "${out}" | grep -o '^[0-9]\+ total' | grep -o '^[0-9]\+')
        t0=$(now_us)
        out=$(run_app "status")
        api_ms=$(ms_since "${t0}")
        [[ -n ${out} ]] || api_ms=""
        [[ -n ${calls} ]] || db_ms=""
        sessions=$(printf '%s\n' "${out}" | awk '/session\(s\) - peak/ { print $1; exit }')
        sps=$(printf '%s\n' "${out}" | awk '/session\(s\) per Sec/ { print $1; exit }')
        idle=$(printf '%s\n' "${out}" | awk '/min idle cpu/ { split($4, a, "/"); print a[2]; exit }')
        # max_sessions em uso (fsctl; muda em runtime com o fs-limites.sh) e ocupacao
        local maxs spct=""
        maxs=$(run_app "fsctl max_sessions" | grep -oE '[0-9]+' | tail -n 1)
        if [[ ${maxs} =~ ^[0-9]+$ && ${sessions} =~ ^[0-9]+$ ]] && ((maxs > 0)); then
            spct=$(fmt1 $((sessions * 1000 / maxs)))
        fi
        # Pool de handles do banco do core (db_cache status: "N total. M in use."). Com M no
        # max-db-handles, a criacao de canal espera ate db-handle-timeout; o aviso do FS nao
        # aparece com loglevel DISABLE, entao a ocupacao e medida aqui.
        local hl htot="" hused="" hpct=""
        hl=$(run_app "db_cache status" | grep -oE '[0-9]+ total\. [0-9]+ in use' | tail -n 1)
        if [[ ${hl} =~ ^([0-9]+)\ total\.\ ([0-9]+)\ in\ use$ ]]; then
            htot=${BASH_REMATCH[1]}
            hused=${BASH_REMATCH[2]}
            if ((FS_MAX_DB_HANDLES > 0)); then
                hpct=$(fmt1 $((hused * 1000 / FS_MAX_DB_HANDLES)))
            fi
        fi
        printf -v APP_LINE ',%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' "${calls}" "${sessions}" "${sps}" "${idle}" "${api_ms}" \
            "${db_ms}" "${maxs}" "${spct}" "${htot}" "${hused}" "${hpct}"
        ;;
    opensips)
        local act early tmu rcv failed drop shu sht shp="" load
        out=$(run_app get_statistics dialog: tm: core: shmem: load:)
        act=$(json_num "${out}" 'dialog:active_dialogs')
        early=$(json_num "${out}" 'dialog:early_dialogs')
        tmu=$(json_num "${out}" 'tm:inuse_transactions')
        rcv=$(json_num "${out}" 'core:rcv_requests')
        failed=$(json_num "${out}" 'dialog:failed_dialogs')
        drop=$(json_num "${out}" 'core:drop_requests')
        shu=$(json_num "${out}" 'shmem:real_used_size')
        sht=$(json_num "${out}" 'shmem:total_size')
        load=$(json_num "${out}" 'load:load')
        if [[ -n ${shu} && -n ${sht} ]] && ((sht > 0)); then
            shp=$(fmt1 $((shu * 1000 / sht)))
        fi
        counter_rate rcv "${rcv}"
        # load_balancer: destino mais cheio (load / max). Perto de 100 o OpenSIPS responde
        # 503 No FreeSWITCH Available, mesmo com o FS abaixo do max-sessions.
        local lbp=""
        if command -v python3 >/dev/null 2>&1; then
            lbp=$(run_app lb_list | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
p = [r["load"] * 100.0 / r["max"] for x in d.get("Destinations", []) for r in x.get("Resources", [])
     if isinstance(r.get("max"), int) and isinstance(r.get("load"), int) and r["max"] > 0 and r["load"] > 0]
print("%.1f" % max(p) if p else "0.0")' 2>/dev/null)
        fi
        printf -v APP_LINE ',%s,%s,%s,%s,%s,%s,%s,%s,%s' "${act}" "${early}" "${tmu}" \
            "${CR}" "${failed}" "${drop}" "${shp}" "${load}" "${lbp}"
        ;;
    db)
        local q sel ins upd thr thc slow rlw lag="" ok="" wq wsq wfc="" wcs wls wpri="" vip=""
        local -A st=()
        local k v
        while read -r k v; do
            [[ -n ${k} ]] && st[${k}]=${v}
        done < <(run_app -N -B -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Questions','Com_select','Com_insert','Com_update','Threads_running','Threads_connected','Slow_queries','Innodb_row_lock_waits','wsrep_local_recv_queue','wsrep_local_send_queue','wsrep_flow_control_paused_ns','wsrep_cluster_size','wsrep_local_state','wsrep_cluster_status')")
        counter_rate q "${st[Questions]:-}"; q=${CR}
        counter_rate sel "${st[Com_select]:-}"; sel=${CR}
        counter_rate ins "${st[Com_insert]:-}"; ins=${CR}
        counter_rate upd "${st[Com_update]:-}"; upd=${CR}
        thr=${st[Threads_running]:-}
        thc=${st[Threads_connected]:-}
        slow=${st[Slow_queries]:-}
        rlw=${st[Innodb_row_lock_waits]:-}
        # Percona XtraDB Cluster (Galera). Vazio quando o servidor nao usa wsrep.
        wq=${st[wsrep_local_recv_queue]:-}
        wsq=${st[wsrep_local_send_queue]:-}
        wcs=${st[wsrep_cluster_size]:-}
        wls=${st[wsrep_local_state]:-}
        # Fracao do intervalo com replicacao pausada por flow control (contador em ns).
        counter_rate fcns "${st[wsrep_flow_control_paused_ns]:-}"
        if [[ -n ${CR} ]]; then
            local fc10=$((CR / 1000000))
            ((fc10 > 1000)) && fc10=1000
            wfc=$(fmt1 "${fc10}")
        fi
        case "${st[wsrep_cluster_status]:-}" in
            "")      wpri="" ;;
            Primary) wpri=1 ;;
            *)       wpri=0 ;;
        esac
        # 1 = o VIP do keepalived esta neste no
        if [[ -n ${DB_VIP} ]] && command -v ip >/dev/null 2>&1; then
            if ip -o -4 addr show 2>/dev/null | grep -q " ${DB_VIP}/"; then vip=1; else vip=0; fi
        fi
        out=$(run_app -e "SHOW REPLICA STATUS\G")
        if [[ $? -eq 0 ]]; then
            if [[ -z ${out} ]]; then
                lag=-1
                ok=-1
            else
                lag=$(printf '%s\n' "${out}" | awk -F': ' '/Seconds_Behind_Source:/ { print ($2 == "NULL" ? "" : $2); exit }')
                if printf '%s\n' "${out}" | grep -q 'Replica_IO_Running: Yes' \
                    && printf '%s\n' "${out}" | grep -q 'Replica_SQL_Running: Yes'; then
                    ok=1
                else
                    ok=0
                fi
            fi
        fi
        # Latencia media das instrucoes no intervalo (performance_schema, todas as sessoes). Exige
        # SELECT em performance_schema; sem permissao ou com performance_schema desligado, fica vazia.
        local pcnt pus stmt="" cpct=""
        read -r pcnt pus < <(run_app -N -B -e "SELECT SUM(COUNT_STAR), SUM(SUM_TIMER_WAIT) DIV 1000000 FROM performance_schema.events_statements_summary_global_by_event_name")
        if [[ ${pcnt:-} =~ ^[0-9]+$ && ${pus:-} =~ ^[0-9]+$ ]]; then
            if [[ -n ${APREV[pcnt]:-} ]] && ((pcnt > APREV[pcnt] && pus >= APREV[pus])); then
                # microssegundos por instrucao -> centesimos de ms
                stmt=$(fmt2 $(( (pus - APREV[pus]) / (pcnt - APREV[pcnt]) / 10 )))
            fi
            APREV[pcnt]=${pcnt}
            APREV[pus]=${pus}
        fi
        if [[ ${thc} =~ ^[0-9]+$ ]] && ((DB_MAXCONN > 0)); then
            cpct=$(fmt1 $((thc * 1000 / DB_MAXCONN)))
        fi
        printf -v APP_LINE ',%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' "${q}" "${sel}" "${ins}" "${upd}" \
            "${thr}" "${thc}" "${slow}" "${rlw}" "${lag}" "${ok}" "${wq}" "${wsq}" "${wfc}" "${wcs}" "${wls}" "${wpri}" "${vip}" \
            "${stmt}" "${cpct}"
        ;;
    web)
        local na="" nreq="" nw="" nwt="" fa="" fidle="" fq="" facc="" fmc="" fsl=""
        local ngx_rps fpm_rps
        if [[ -n ${NGINX_URL} ]]; then
            out=$(timeout "${CMD_TIMEOUT}" curl -fsk -m 3 "${NGINX_URL}" 2>/dev/null)
            na=$(printf '%s\n' "${out}" | awk '/^Active connections:/ { print $3 }')
            nreq=$(printf '%s\n' "${out}" | awk 'NR == 3 { print $3 }')
            nw=$(printf '%s\n' "${out}" | awk '/^Reading:/ { print $4 }')
            nwt=$(printf '%s\n' "${out}" | awk '/^Reading:/ { print $6 }')
        fi
        if [[ -n ${FPM_URL} ]]; then
            out=$(timeout "${CMD_TIMEOUT}" curl -fsk -m 3 "${FPM_URL}" 2>/dev/null)
            fa=$(json_num "${out}" 'active processes')
            fidle=$(json_num "${out}" 'idle processes')
            fq=$(json_num "${out}" 'listen queue')
            facc=$(json_num "${out}" 'accepted conn')
            fmc=$(json_num "${out}" 'max children reached')
            fsl=$(json_num "${out}" 'slow requests')
        fi
        counter_rate nreq "${nreq}"; ngx_rps=${CR}
        counter_rate facc "${facc}"; fpm_rps=${CR}
        printf -v APP_LINE ',%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' "${na}" "${ngx_rps}" \
            "${nw}" "${nwt}" "${fa}" "${fidle}" "${fq}" "${fpm_rps}" "${fmc}" "${fsl}"
        ;;
    gen)
        ;;
    esac
}

# ---------------------------------------------------------------- laco
header="ts,cpu_pct,cpu_max_core_pct,cpu_max_core,iowait_pct,steal_pct,softirq_pct,load1"
header+=",mem_used_pct,mem_avail_mb,swap_used_mb"
header+=",net_rx_mbps,net_tx_mbps,net_rx_pps,net_tx_pps,udp_in_err_s,udp_rcvbuf_err_s,net_rx_drop_s,net_tx_drop_s"
header+=",disk_rd_kbs,disk_wr_kbs,disk_busy_pct,disk_free_pct"
for g in "${PROC_LIST[@]}"; do
    gname=$(proc_group_name "${g}")
    header+=",${gname}_cpu_pct,${gname}_rss_mb,${gname}_threads,${gname}_max_thread_pct"
done
header+="$(app_header)"
printf '%s\n' "${header}" || exit 0

read_cpu; save_cpu
read_net; P_RB=${NET_RB} P_RP=${NET_RP} P_TB=${NET_TB} P_TP=${NET_TP} P_RD=${NET_RD} P_TD=${NET_TD}
read_udp; P_UE=${UDP_ERR} P_UR=${UDP_RCVBUF}
read_disk
for k in "${!DRD[@]}"; do PDRD[${k}]=${DRD[${k}]}; PDWR[${k}]=${DWR[${k}]}; PDTK[${k}]=${DTK[${k}]}; done
read_uptime_ticks
sample_procs; save_procs; sample_threads
PREV_UPTIME_TICKS=${UPTIME_TICKS}
DT_MS=$((INTERVAL * 1000))
FS_MAX_DB_HANDLES=0
if [[ ${ROLE} == fs ]]; then
    # max-db-handles do switch.conf (padrao do FS: 50). Lido uma vez: so muda com restart.
    FS_MAX_DB_HANDLES=$(run_app "xml_locate configuration configuration name switch.conf" | tr '>' '\n' \
        | sed -n 's/.*<param[[:space:]][^<]*name="max-db-handles"[^<]*value="\([0-9]*\)".*/\1/p' | head -n 1)
    [[ ${FS_MAX_DB_HANDLES} =~ ^[0-9]+$ ]] || FS_MAX_DB_HANDLES=50
fi
DB_MAXCONN=0
if [[ ${ROLE} == db ]]; then
    DB_MAXCONN=$(run_app -N -B -e "SELECT @@max_connections")
    [[ ${DB_MAXCONN} =~ ^[0-9]+$ ]] || DB_MAXCONN=0
fi
app_sample
PREV_US=$(now_us)
START_S=${SECONDS}

while ((SECONDS - START_S < MAX_SECONDS)); do
    sleep "${INTERVAL}"
    NOW_US=$(now_us)
    DT_MS=$(( (NOW_US - PREV_US) / 1000 ))
    ((DT_MS > 0)) || DT_MS=1
    PREV_US=${NOW_US}
    printf -v TS '%(%s)T' -1

    # CPU total e nucleo mais carregado
    read_cpu
    dt=$((CT[cpu] - PCT[cpu]))
    ((dt > 0)) || dt=1
    cpu=$(fmt1 $(( (dt - (CI[cpu] - PCI[cpu])) * 1000 / dt )))
    iow=$(fmt1 $(( (CW[cpu] - PCW[cpu]) * 1000 / dt )))
    stl=$(fmt1 $(( (CST[cpu] - PCST[cpu]) * 1000 / dt )))
    sirq=$(fmt1 $(( (CS[cpu] - PCS[cpu]) * 1000 / dt )))
    max_core=-1 max_core_id=""
    for k in "${!CT[@]}"; do
        [[ ${k} == cpu ]] && continue
        [[ -n ${PCT[${k}]:-} ]] || continue
        d=$((CT[${k}] - PCT[${k}]))
        ((d > 0)) || continue
        v=$(( (d - (CI[${k}] - PCI[${k}])) * 1000 / d ))
        if ((v > max_core)); then max_core=${v}; max_core_id=${k#cpu}; fi
    done
    ((max_core < 0)) && max_core=0
    save_cpu

    read -r load1 _ < /proc/loadavg

    # Memoria
    read -r mt ma swt swf < <(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
        /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
        END { printf "%d %d %d %d\n", t, a, st, sf }' /proc/meminfo)
    ((mt > 0)) || mt=1
    mem_pct=$(fmt1 $(( (mt - ma) * 1000 / mt )))
    mem_avail=$((ma / 1024))
    swap_used=$(( (swt - swf) / 1024 ))

    # Rede (todas as interfaces exceto lo)
    read_net
    rx_mbps=$(fmt2 $(( (NET_RB - P_RB) * 8 * 100 / 1000 / DT_MS )))
    tx_mbps=$(fmt2 $(( (NET_TB - P_TB) * 8 * 100 / 1000 / DT_MS )))
    rx_pps=$(rate $((NET_RP - P_RP)))
    tx_pps=$(rate $((NET_TP - P_TP)))
    rx_drop=$(rate $((NET_RD - P_RD)))
    tx_drop=$(rate $((NET_TD - P_TD)))
    P_RB=${NET_RB} P_RP=${NET_RP} P_TB=${NET_TB} P_TP=${NET_TP} P_RD=${NET_RD} P_TD=${NET_TD}
    read_udp
    ue=$(rate $((UDP_ERR - P_UE)))
    ur=$(rate $((UDP_RCVBUF - P_UR)))
    P_UE=${UDP_ERR} P_UR=${UDP_RCVBUF}

    # Disco: soma de leitura/escrita e o disco mais ocupado
    read_disk
    rd=0 wr=0 busy=0
    for k in "${!DRD[@]}"; do
        [[ -n ${PDRD[${k}]:-} ]] || continue
        rd=$((rd + DRD[${k}] - PDRD[${k}]))
        wr=$((wr + DWR[${k}] - PDWR[${k}]))
        b=$(( (DTK[${k}] - PDTK[${k}]) * 1000 / DT_MS ))
        ((b > busy)) && busy=${b}
    done
    ((busy > 1000)) && busy=1000
    PDRD=() PDWR=() PDTK=()
    for k in "${!DRD[@]}"; do PDRD[${k}]=${DRD[${k}]}; PDWR[${k}]=${DWR[${k}]}; PDTK[${k}]=${DTK[${k}]}; done
    # setores de 512 bytes -> KB/s
    rd_kbs=$(rate $((rd / 2)))
    wr_kbs=$(rate $((wr / 2)))
    free_pct=$(disk_free_pct)

    line="${TS},${cpu},$(fmt1 "${max_core}"),${max_core_id},${iow},${stl},${sirq},${load1}"
    line+=",${mem_pct},${mem_avail},${swap_used}"
    line+=",${rx_mbps},${tx_mbps},${rx_pps},${tx_pps},${ue},${ur},${rx_drop},${tx_drop}"
    line+=",${rd_kbs},${wr_kbs},$(fmt1 "${busy}"),${free_pct}"

    # Processos do servico (100% = 1 nucleo)
    read_uptime_ticks
    sample_procs
    sample_threads
    for g in "${PROC_LIST[@]}"; do
        gname=$(proc_group_name "${g}")
        pc=$(( G_CPU[${gname}] * 100 * 1000 * 10 / CLK_TCK / DT_MS ))
        mt=$(( ${G_MAXT[${gname}]:-0} * 100 * 1000 * 10 / CLK_TCK / DT_MS ))
        line+=",$(fmt1 "${pc}"),$((G_RSS[${gname}] / 1024)),${G_THR[${gname}]},$(fmt1 "${mt}")"
    done
    save_procs
    PREV_UPTIME_TICKS=${UPTIME_TICKS}

    app_sample
    line+="${APP_LINE}"
    printf '%s\n' "${line}" || exit 0
done
