#!/usr/bin/env bash
#
# coleta-longa.sh - coleta para testes longos nos servidores do STFC (T4, stfc-cps90-2h; WEB-1437)
#
# Complementa as metricas de 5 s do flux-loadtest com o que um teste longo precisa para achar
# vazamento e crescimento: memoria por processo (RSS, PSS e VmHWM), shm e pkg do OpenSIPS por
# amostra, estado e limites do FreeSWITCH, contadores do banco e o que cresceu no disco.
#
# Uso (root em cada servidor, dentro de um tmux, iniciado logo antes do disparo):
#   bash coleta-longa.sh <segundos> [intervalo_s]
#   ex.: bash coleta-longa.sh 7900        T4: ~2h08 de teste + margem, uma amostra a cada 60 s
#        bash coleta-longa.sh 120 10      validacao rapida do pacote antes do teste
#
# Papeis detectados pelo processo em execucao: opensips, freeswitch e mysqld (o .163 tem os dois
# primeiros). Somente leitura: /proc, df, du, find, journalctl, opensips-cli (get_statistics, ps,
# lb_list, xlog_level), fs_cli (status, show calls count, fsctl sps/max_sessions sem valor, que so
# consulta), mysql (SHOW GLOBAL STATUS, information_schema.processlist). Nao altera configuracao.
# fs_cli e mysql usam a configuracao local do root (~/.fs_cli_conf, ~/.my.cnf): nenhuma senha na
# linha de comando. Ctrl+C, TERM ou queda do SSH (HUP) encerram a coleta e geram o pacote assim mesmo.
# Carga: um ciclo de comandos por intervalo; du dos diretorios do FS a cada 5 amostras; du dos
# pontos de montagem no inicio (em segundo plano) e no fim; find so no fim.
#
# Saida: /root/coleta-longa-<host>-<data>/ e o pacote /root/coleta-longa-<host>-<data>.tar.gz
#   contexto-inicio.txt, contexto-fim.txt  versoes, uptime, memoria, disco, journald, limites do FS
#   sistema.tsv            memoria do host, swap, load, erros UDP, uso de /
#   processos.tsv          por servico: processos, RSS e PSS somados, maior VmHWM, threads, fds
#   opensips-stats.log     get_statistics shmem: pkmem: dialog: tm: core: (uma linha por amostra)
#   opensips-inicio.txt, opensips-fim.txt  mi ps, lb_list, xlog_level, argumentos do processo
#   fs.tsv                 sessoes ativas, desde o start e pico; sps e max_sessions; idle cpu; chamadas
#   fs-dirs.tsv            MB dos diretorios do FreeSWITCH e do journal
#   db.tsv                 contadores do SHOW GLOBAL STATUS
#   db-conexoes.log        conexoes por usuario e origem
#   arquivos-crescidos.txt crescimento do disco: uso por ponto de montagem, diretorios que mais
#                          cresceram (du no inicio x no fim) e arquivos grandes alterados
#   du-inicio.txt, du-fim.txt  du -xm ate 3 niveis por ponto de montagem local (base do crescimento)

set -uo pipefail
export LC_ALL=C

DUR=${1:-}
INT=${2:-60}

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

[[ ${DUR} =~ ^[0-9]+$ ]] && ((DUR >= 60 && DUR <= 14400)) || die "informe a duracao em segundos (60 a 14400)"
[[ ${INT} =~ ^[0-9]+$ ]] && ((INT >= 10 && INT <= 600)) || die "intervalo deve ser de 10 a 600 s"
((INT <= DUR)) || die "intervalo maior que a duracao"
((EUID == 0)) || die "rode como root"
for c in timeout df du find tar awk pgrep; do
    command -v "${c}" >/dev/null 2>&1 || die "comando nao encontrado: ${c}"
done

ROLE_OS=0 ROLE_FS=0 ROLE_DB=0
pgrep -x opensips >/dev/null 2>&1 && command -v opensips-cli >/dev/null 2>&1 && ROLE_OS=1
pgrep -x freeswitch >/dev/null 2>&1 && command -v fs_cli >/dev/null 2>&1 && ROLE_FS=1
pgrep -x mysqld >/dev/null 2>&1 && command -v mysql >/dev/null 2>&1 && ROLE_DB=1
((ROLE_OS + ROLE_FS + ROLE_DB > 0)) || die "nenhum servico reconhecido (opensips, freeswitch, mysqld)"

HOST=$(hostname -s 2>/dev/null || hostname)
NAME=coleta-longa-${HOST}-$(date +%Y%m%d-%H%M%S)
OUT=/root/${NAME}
mkdir -p "${OUT}" || die "nao foi possivel criar ${OUT}"
touch "${OUT}/.inicio" || die "nao foi possivel gravar em ${OUT}"

# Mascara user:senha@ em URLs e valores de parametros com pass/secret/password
mask() { sed -E 's#(://[^:/@ ]+:)[^@ ]+@#\1***@#g; s#((pass|secret|password)[a-z_]*"?[[:space:]]*[,=:][[:space:]]*"?)[^",; )]+#\1***#Ig'; }

fsx() { timeout 10 fs_cli -x "$1" 2>/dev/null; }
osx() { timeout 10 opensips-cli -x mi "$@" 2>/dev/null; }
dbx() { timeout 10 mysql -N -B -e "$1" 2>/dev/null; }

# Ultimo numero da resposta do fsctl sem valor ("+OK ...: N"), que so consulta
fsctl_val() { fsx "fsctl $1" | grep -oE '[0-9]+' | tail -n 1; }

meminfo() { awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo; }

# Coluna do Udp: em /proc/net/snmp (primeira linha = nomes, segunda = valores)
udp_snmp() {
    awk -v col="$1" '$1 == "Udp:" { if (!h) { for (i = 2; i <= NF; i++) if ($i == col) c = i; h = 1; next }
        if (c) print $c; exit }' /proc/net/snmp
}

# processos <nome>: n, rss_kb, pss_kb, hwm_kb (maior), threads, fds
processos() {
    local pid n=0 rss=0 pss=0 hwm=0 thr=0 fds=0 r h t p f
    for pid in $(pgrep -x "$1"); do
        [[ -r /proc/${pid}/status ]] || continue
        r=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/${pid}/status" 2>/dev/null)
        h=$(awk '$1 == "VmHWM:" { print $2 }' "/proc/${pid}/status" 2>/dev/null)
        t=$(awk '$1 == "Threads:" { print $2 }' "/proc/${pid}/status" 2>/dev/null)
        p=$(awk '$1 == "Pss:" { print $2 }' "/proc/${pid}/smaps_rollup" 2>/dev/null)
        f=$(find "/proc/${pid}/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        n=$((n + 1)); rss=$((rss + ${r:-0})); pss=$((pss + ${p:-0})); thr=$((thr + ${t:-0})); fds=$((fds + ${f:-0}))
        ((${h:-0} > hwm)) && hwm=${h:-0}
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s' "${n}" "${rss}" "${pss}" "${hwm}" "${thr}" "${fds}"
}

# fs_status: ativas, desde_start, pico, sps_pico, idle_cpu (da saida do "status")
fs_status() {
    fsx status | awk '
        / session\(s\) since startup/ { since = $1 }
        / session\(s\) - peak / { act = $1; pk = $5; sub(/,/, "", pk) }
        / session\(s\) per Sec / { for (i = 1; i <= NF; i++) if ($i == "peak") { sp = $(i + 1); sub(/,/, "", sp) } }
        /min idle cpu/ { n = split($NF, a, "/"); idle = a[n] }
        END { printf "%s\t%s\t%s\t%s\t%s", act, since, pk, sp, idle }'
}

DB_VARS="Threads_connected Threads_running Max_used_connections Connection_errors_max_connections Aborted_connects Aborted_clients Questions Slow_queries wsrep_local_state_comment wsrep_cluster_size wsrep_flow_control_paused wsrep_local_recv_queue wsrep_local_send_queue"

db_status() {
    local in
    # shellcheck disable=SC2086  # DB_VARS e uma lista separada por espacos, de proposito
    in=$(printf "'%s'," ${DB_VARS}); in=${in%,}
    dbx "SHOW GLOBAL STATUS WHERE Variable_name IN (${in})" | awk -v vars="${DB_VARS}" '
        { val[$1] = $2 }
        END { n = split(vars, k, " "); for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "\t" : ""), val[k[i]] }'
}

FS_DIRS="/var/lib/freeswitch/db /var/lib/freeswitch/recordings /var/lib/freeswitch/storage /var/log/freeswitch /var/log/nginx /var/log/journal"

contexto() { # $1 = rotulo
    printf '== %s %s (%s)\n' "$1" "$(date '+%F %T')" "${HOST}"
    printf 'papeis: opensips=%s freeswitch=%s mysqld=%s  intervalo=%ss duracao=%ss\n' "${ROLE_OS}" "${ROLE_FS}" "${ROLE_DB}" "${INT}" "${DUR}"
    printf '\n== uptime / kernel / nproc\n'; uptime; uname -r; nproc
    printf '\n== free -m\n'; free -m
    printf '\n== df -Pm (locais)\n'; df -Pm -l -x tmpfs -x devtmpfs -x squashfs -x overlay 2>&1
    printf '\n== journalctl --disk-usage\n'; timeout 10 journalctl --disk-usage 2>&1
    printf '\n== Udp em /proc/net/snmp\n'; grep '^Udp:' /proc/net/snmp
    if ((ROLE_OS)); then
        printf '\n== opensips -V\n'; timeout 5 opensips -V 2>&1 | head -n 2
    fi
    if ((ROLE_FS)); then
        printf '\n== fs_cli version / status\n'; fsx version; fsx status
        printf '\n== limites em uso: sps=%s max_sessions=%s\n' "$(fsctl_val sps)" "$(fsctl_val max_sessions)"
        printf '== estado do fs-limites (/root/flux-loadtest-fs-limites.antes): '
        if [[ -r /root/flux-loadtest-fs-limites.antes ]]; then tr '\n' ' ' < /root/flux-loadtest-fs-limites.antes; echo; else echo ausente; fi
        printf '\n== switch.conf.xml (sessions-per-second, max-sessions)\n'
        grep -nE 'sessions-per-second|max-sessions' /etc/freeswitch/autoload_configs/switch.conf.xml 2>&1
    fi
    if ((ROLE_DB)); then
        printf '\n== mysql\n'; dbx 'SELECT VERSION()'
        dbx "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('max_connections','innodb_buffer_pool_size','wsrep_cluster_name')"
        printf '\n== SHOW GLOBAL STATUS (contadores)\n'
        paste <(tr ' ' '\n' <<< "${DB_VARS}") <(db_status | tr '\t' '\n')
    fi
}

opensips_ctx() { # $1 = rotulo
    printf '== %s %s\n' "$1" "$(date '+%F %T')"
    printf '\n== argumentos do processo principal\n'; ps -o pid=,args= -p "$(pgrep -o -x opensips)" 2>&1 | mask
    printf '\n== mi xlog_level\n'; osx xlog_level
    printf '\n== mi ps\n'; osx ps
    printf '\n== mi lb_list\n'; osx lb_list
}

# Cabecalhos
printf 'epoch\thora\tmem_avail_mb\tcached_mb\tslab_mb\tswap_usado_mb\tload1\tudp_inerrors\tudp_rcvbuf_errors\traiz_usado_mb\traiz_pct\n' > "${OUT}/sistema.tsv"
printf 'epoch\thora\tservico\tprocessos\trss_kb\tpss_kb\thwm_kb_max\tthreads\tfds\n' > "${OUT}/processos.tsv"
((ROLE_FS)) && printf 'epoch\thora\tsessoes\tdesde_start\tpico\tsps_pico\tidle_cpu\tsps_limite\tmax_sessions\tchamadas\n' > "${OUT}/fs.tsv"
((ROLE_FS)) && printf 'epoch\thora\tdiretorio\tmb\n' > "${OUT}/fs-dirs.tsv"
((ROLE_DB)) && printf 'epoch\thora\t%s\n' "$(tr ' ' '\t' <<< "${DB_VARS}")" > "${OUT}/db.tsv"

contexto inicio > "${OUT}/contexto-inicio.txt" 2>&1
df -Pm -l -x tmpfs -x devtmpfs -x squashfs -x overlay > "${OUT}/.df-inicio" 2>/dev/null
((ROLE_OS)) && opensips_ctx inicio > "${OUT}/opensips-inicio.txt" 2>&1

amostra() { # $1 = numero da amostra
    local ep hora a c s st sf su l1 rest df_l svc
    ep=$(date +%s); hora=$(date +%T)
    a=$(meminfo MemAvailable); c=$(meminfo Cached); s=$(meminfo Slab)
    st=$(meminfo SwapTotal); sf=$(meminfo SwapFree); su=$(( ${st:-0} - ${sf:-0} ))
    read -r l1 rest < /proc/loadavg
    df_l=$(df -Pm / 2>/dev/null | awk 'NR == 2 { sub(/%/, "", $5); print $3 "\t" $5 }')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${ep}" "${hora}" "$((${a:-0} / 1024))" "$((${c:-0} / 1024))" \
        "$((${s:-0} / 1024))" "$((su / 1024))" "${l1}" "$(udp_snmp InErrors)" "$(udp_snmp RcvbufErrors)" "${df_l}" >> "${OUT}/sistema.tsv"

    for svc in opensips freeswitch mysqld; do
        pgrep -x "${svc}" >/dev/null 2>&1 || continue
        printf '%s\t%s\t%s\t%s\n' "${ep}" "${hora}" "${svc}" "$(processos "${svc}")" >> "${OUT}/processos.tsv"
    done

    if ((ROLE_OS)); then
        printf '%s %s ' "${ep}" "${hora}" >> "${OUT}/opensips-stats.log"
        osx get_statistics shmem: pkmem: dialog: tm: core: | tr -d '\n' | tr -s ' ' >> "${OUT}/opensips-stats.log"
        printf '\n' >> "${OUT}/opensips-stats.log"
    fi

    if ((ROLE_FS)); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${ep}" "${hora}" "$(fs_status)" "$(fsctl_val sps)" "$(fsctl_val max_sessions)" \
            "$(fsx 'show calls count' | grep -oE '^[0-9]+' | head -n 1)" >> "${OUT}/fs.tsv"
        if (($1 % 5 == 1)); then
            local d
            for d in ${FS_DIRS}; do
                [[ -d ${d} ]] || continue
                printf '%s\t%s\t%s\t%s\n' "${ep}" "${hora}" "${d}" "$(timeout 60 du -sm "${d}" 2>/dev/null | awk '{ print $1 }')" >> "${OUT}/fs-dirs.tsv"
            done
        fi
    fi

    if ((ROLE_DB)); then
        printf '%s\t%s\t%s\n' "${ep}" "${hora}" "$(db_status)" >> "${OUT}/db.tsv"
        {
            printf '== %s\n' "${hora}"
            dbx "SELECT user, SUBSTRING_INDEX(host, ':', 1), COUNT(*) FROM information_schema.processlist GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 8"
        } >> "${OUT}/db-conexoes.log"
    fi
}

montagens() { df -P -l -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR > 1 { print $6 }'; }

du_snap() { # $1 = arquivo de saida: "MB<TAB>diretorio" ate 3 niveis, por ponto de montagem local
    local m
    for m in $(montagens); do
        timeout 600 du -xm --max-depth=3 "${m}" 2>/dev/null
    done > "$1"
}

crescidos() { # crescimento do disco durante a coleta
    local m
    printf '== crescimento do disco entre %s e %s\n' "$(date -r "${OUT}/.inicio" '+%F %T')" "$(date '+%F %T')"
    printf '\n== uso por ponto de montagem (MB usados no inicio, no fim, diferenca)\n'
    awk 'NR == FNR { if (FNR > 1) u[$6] = $3; next } FNR > 1 && ($6 in u) { printf "%s\t%s\t%s\t%+d\n", $6, u[$6], $3, $3 - u[$6] }' \
        "${OUT}/.df-inicio" <(df -Pm -l -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null)
    printf '\n== diretorios que mais cresceram (MB no inicio, no fim, diferenca; du ate 3 niveis)\n'
    if [[ -s ${OUT}/du-inicio.txt && -s ${OUT}/du-fim.txt ]]; then
        awk -F'\t' 'NR == FNR { a[$2] = $1; next } { d = $1 - a[$2]; if (d > 0) printf "%d\t%d\t%d\t%s\n", a[$2], $1, d, $2 }' \
            "${OUT}/du-inicio.txt" "${OUT}/du-fim.txt" | sort -t$'\t' -k3,3nr | head -n 25
    else
        printf '(du do inicio ou do fim ausente)\n'
    fi
    for m in $(montagens); do
        printf '\n== %s: arquivos acima de 10 MB alterados durante a coleta (tamanho atual, nao o crescimento)\n' "${m}"
        timeout 300 find "${m}" -xdev -type f -newer "${OUT}/.inicio" -size +10M -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null \
            | grep -v "${OUT}" | sort -rn | head -n 30
    done
}

PARAR=0
trap 'PARAR=1' INT TERM HUP

# Base do crescimento do disco, em segundo plano para nao atrasar a primeira amostra
du_snap "${OUT}/du-inicio.txt" &
DU_PID=$!

printf 'coletando %ss a cada %ss em %s (opensips=%s freeswitch=%s mysqld=%s)\n' "${DUR}" "${INT}" "${OUT}" "${ROLE_OS}" "${ROLE_FS}" "${ROLE_DB}"
fim=$((SECONDS + DUR)); n=0
while ((SECONDS < fim && PARAR == 0)); do
    n=$((n + 1)); prox=$((SECONDS + INT))
    amostra "${n}" 2>>"${OUT}/erros.log"
    ((n % 10 == 0)) && printf '%s amostra %s, faltam %ss\n' "$(date +%T)" "${n}" "$((fim - SECONDS))"
    espera=$((prox - SECONDS))
    ((espera > 0 && PARAR == 0)) && { sleep "${espera}" & wait $!; }
done
trap '' INT TERM HUP

((PARAR)) && printf 'interrompido na amostra %s: fechando o pacote\n' "${n}"
printf 'finalizando: contexto, du e busca de arquivos alterados (ate alguns minutos)\n'
contexto fim > "${OUT}/contexto-fim.txt" 2>&1
((ROLE_OS)) && opensips_ctx fim > "${OUT}/opensips-fim.txt" 2>&1
wait "${DU_PID}" 2>/dev/null
du_snap "${OUT}/du-fim.txt"
crescidos > "${OUT}/arquivos-crescidos.txt" 2>&1
[[ -s ${OUT}/erros.log ]] || rm -f "${OUT}/erros.log"

if tar -C /root -czf "${OUT}.tar.gz" "${NAME}"; then
    printf 'fim: %s amostras. Envie %s.tar.gz\n' "${n}" "${OUT}"
else
    printf 'AVISO: falha ao gerar o pacote; envie a pasta %s\n' "${OUT}" >&2
    exit 1
fi
