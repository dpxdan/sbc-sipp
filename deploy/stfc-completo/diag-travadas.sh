#!/usr/bin/env bash
#
# diag-travadas.sh - estado do OpenSIPS durante as travadas do socket 5060 (WEB-1437)
#
# As travadas de 1 a 2 s se repetem em ciclo de 150 s (56,5 + 56,5 + 37 s) sob carga. Este
# script fotografa o que cada processo do OpenSIPS esta esperando (wchan) no momento em que a
# fila do socket cresce, e mede o tempo de resposta do MI e o "max" do load_balancer a cada 1 s.
#
# Uso (root no sbc-stfc-1, .163), iniciado logo antes do disparo:
#   bash diag-travadas.sh <segundos> [limiar_bytes] [ip]
#
# Somente leitura: ss, ps, top, opensips-cli (mi ps, lb_list), systemctl list-timers, crontab -l.
# Nao altera configuracao nem reinicia servicos. Senhas em URLs e parametros sao mascaradas.
# Carga: um opensips-cli por segundo e, com fila acima do limiar, um ps e um top por segundo.
#
# Saida em /root/diag-travadas-<data>/:
#   contexto.txt  processos do OpenSIPS, modulos e modparams, timers e cron, heartbeat do FS
#   fila.log      a cada 0,2 s: hora, fila 5060 (bytes), fila 5070 do FS, load1, executando/total
#   travadas.log  com fila acima do limiar (no maximo 1 por segundo): estado e wchan de cada
#                 processo do OpenSIPS e as threads mais carregadas do servidor
#   lb.log        a cada 1 s: hora, tempo de resposta do lb_list (ms) e "max" dos destinos

set -uo pipefail
export LC_ALL=C

DUR=${1:-}
LIM=${2:-50000}
IP=${3:-200.159.177.163}

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

[[ $DUR =~ ^[0-9]+$ ]] && ((DUR > 0 && DUR <= 10800)) || die "informe a duracao em segundos (1 a 10800)"
[[ $LIM =~ ^[0-9]+$ ]] || die "limiar deve ser inteiro (bytes)"
[[ $IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "ip invalido: ${IP}"
((EUID == 0)) || die "rode como root"
for c in ss ps top pgrep opensips-cli; do
    command -v "$c" >/dev/null 2>&1 || die "comando nao encontrado: ${c}"
done
pgrep -x opensips >/dev/null || die "opensips nao esta rodando"

OUT=/root/diag-travadas-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT" || die "nao foi possivel criar ${OUT}"

# Mascara user:senha@ em URLs e valores de parametros com pass/secret/password
mask() { sed -E 's#(://[^:/@ ]+:)[^@ ]+@#\1***@#g; s#((pass|secret|password)[a-z_]*"?[[:space:]]*[,=:][[:space:]]*"?)[^",; )]+#\1***#Ig'; }

fila() { # bytes na fila de recepcao do socket UDP <ip>:<porta>
    local q
    q=$(ss -Hlunm "src ${IP}:$1" 2>/dev/null | grep -o 'skmem:(r[0-9]*' | head -n 1)
    printf '%s' "${q#skmem:(r}"
}

dump() { # $1 = rotulo
    printf '== %s %s\n' "$(date +%T.%3N)" "$1"
    ps -L -o pid=,tid=,stat=,wchan:32=,comm= -C opensips
    printf -- '-- threads mais carregadas (0,2 s)\n'
    top -b -H -n 2 -d 0.2 -w 180 2>/dev/null | awk '/^top -/{f++} f==2' | sed -n '1,5p;7,26p'
}

{
    printf 'inicio %s  duracao %ss  limiar %s bytes  ip %s\n' "$(date '+%F %T')" "$DUR" "$LIM" "$IP"
    printf '\n== opensips-cli -x mi ps\n'; timeout 10 opensips-cli -x mi ps 2>&1
    CFG=/etc/opensips/opensips.cfg
    printf '\n== %s (loadmodule, modparam, workers, timer_route)\n' "$CFG"
    grep -nE '^[[:space:]]*(loadmodule|modparam|udp_workers|tcp_workers|children|timer_route|socket|listen)' "$CFG" 2>&1 | mask
    printf '\n== heartbeat do FreeSWITCH\n'
    grep -rnE 'heartbeat' /etc/freeswitch/autoload_configs/switch.conf.xml /etc/freeswitch/autoload_configs/event_socket.conf.xml 2>&1 | mask
    printf '\n== systemctl list-timers\n'; systemctl list-timers --all --no-pager 2>&1
    printf '\n== crontab -l (root)\n'; crontab -l 2>&1 | mask
    printf '\n== /etc/cron.d\n'; grep -vE '^[[:space:]]*(#|$)' /etc/cron.d/* 2>&1 | mask
    printf '\n== processos php, python, lua e flux (pid, segundos de vida, comando)\n'
    ps -eo pid,etimes,args --sort=start_time | grep -iE 'php|python|lua|flux' | grep -v grep | mask
    printf '\n'; dump "referencia (antes da carga)"
} > "$OUT/contexto.txt" 2>&1

# lb_list a cada 1 s, medindo quanto o MI demora a responder
(
    end=$((SECONDS + DUR))
    while ((SECONDS < end)); do
        t0=$(date +%s%3N)
        mx=$(timeout 5 opensips-cli -x mi lb_list 2>/dev/null | grep -o '"max": [0-9]*' | tr -d '"' | tr '\n' ' ')
        printf '%s %sms %s\n' "$(date +%T.%3N)" "$(( $(date +%s%3N) - t0 ))" "${mx:-sem_resposta}"
        sleep 1
    done
) > "$OUT/lb.log" 2>&1 &
LBPID=$!
trap 'kill "$LBPID" 2>/dev/null; wait "$LBPID" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP

printf 'capturando %ss em %s\n' "$DUR" "$OUT"
end=$((SECONDS + DUR)); ultimo=-1; n=0
while ((SECONDS < end)); do
    q=$(fila 5060); q=${q:-0}
    read -r l1 _ _ rq _ < /proc/loadavg
    printf '%s %s %s %s %s\n' "$(date +%T.%3N)" "$q" "$(fila 5070)" "$l1" "$rq" >> "$OUT/fila.log"
    if ((q > LIM && SECONDS != ultimo)); then
        ultimo=$SECONDS; n=$((n + 1))
        dump "fila=${q}" >> "$OUT/travadas.log" 2>&1
    fi
    sleep 0.2
done

printf 'fim: %s capturas acima de %s bytes. Envie a pasta %s\n' "$n" "$LIM" "$OUT"
