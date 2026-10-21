#!/usr/bin/env bash
#
# preflight-sbc.sh - verificacao SOMENTE LEITURA do sbc-stfc-1 (OpenSIPS + FS) e do sbc-stfc-02
# (FS) antes do teste de carga completo pelo OpenSIPS (WEB-1437). Nada e alterado.
#
# Uso (root em cada SBC):  bash preflight-sbc.sh [IP_DO_GERADOR]
# Saida: linhas "ok", "AVISO" e "FALHA"; codigo 1 se houver FALHA.

set -uo pipefail
export LC_ALL=C

GEN_IP=${1:-200.159.177.165}
FAIL=0

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  AVISO %s\n' "$*"; }
fail() { printf '  FALHA %s\n' "$*"; FAIL=$((FAIL + 1)); }
sec()  { printf -- '-- %s\n' "$*"; }

[[ ${GEN_IP} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "uso: $0 [IP_DO_GERADOR]"; exit 2; }
((EUID == 0)) || { echo "rode como root (fs_cli, opensips-cli, sudo -l, firewall)"; exit 2; }

fsx() { timeout 10 fs_cli -x "$1" 2>/dev/null; }
mi()  { timeout 10 opensips-cli -x mi "$@" 2>/dev/null; }

printf '== %s, gerador %s\n' "$(hostname)" "${GEN_IP}"
printf '   %s vCPU, load %s, memoria disponivel %s MB\n' "$(nproc)" "$(cut -d' ' -f1-3 /proc/loadavg)" \
    "$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)"

sec "FreeSWITCH"
if systemctl is-active --quiet freeswitch; then ok "servico freeswitch ativo"; else fail "freeswitch inativo"; fi
st=$(fsx status)
if [[ -n ${st} ]]; then
    ok "fs_cli responde (root)"
    printf '%s\n' "${st}" | grep -E 'session\(s\)' | sed 's/^/        /'
else
    fail "fs_cli sem resposta como root: crie /root/.fs_cli_conf (README, secao 2.1)"
    es=/etc/freeswitch/autoload_configs/event_socket.conf.xml
    # so IP e porta; a senha nao e exibida
    [[ -r ${es} ]] && grep -oE 'name="(listen-ip|listen-port)" value="[^"]*"' "${es}" | sed 's/^/        event_socket: /'
fi
sps=$(fsx 'fsctl sps' | grep -oE '[0-9]+' | tail -n 1)
max=$(fsx 'fsctl max_sessions' | grep -oE '[0-9]+' | tail -n 1)
[[ -n ${sps} && -n ${max} ]] && warn "limites atuais: sps=${sps} max_sessions=${max}; com bridge para o atendedor cada chamada abre 2 sessoes (teto deste no ~$((sps / 2)) CPS e ~$((max / 2)) chamadas, menos o trafego real). Ajuste com fs-limites.sh"
ch=$(fsx 'show channels count' | awk '/total/ { print $1 }')
[[ -n ${ch} ]] && ok "canais em uso agora: ${ch} (trafego real)"
pid=$(pidof freeswitch 2>/dev/null | awk '{ print $1 }')
if [[ -n ${pid} ]]; then
    nofile=$(awk '/Max open files/ { print $4 }' "/proc/${pid}/limits")
    if [[ ${nofile} =~ ^[0-9]+$ ]] && ((nofile < 65536)); then
        warn "FreeSWITCH com ${nofile} arquivos abertos no maximo: limita sessoes e RTP em carga alta"
    else
        ok "FreeSWITCH: Max open files ${nofile}"
    fi
fi
prof=$(fsx 'sofia status profile default')
printf '%s\n' "${prof}" | grep -E '^(BIND-URL|RTP-IP|EXT-RTP-IP|STATE|CALLS-IN|FAILED-CALLS-IN)' | sed 's/^/        /'
sw=/etc/freeswitch/autoload_configs/switch.conf.xml
[[ -r ${sw} ]] && grep -oE 'name="(max-sessions|sessions-per-second|rtp-start-port|rtp-end-port)" value="[^"]*"' "${sw}" | sed 's/^/        switch.conf: /'

if command -v opensips-cli >/dev/null 2>&1 && systemctl is-active --quiet opensips; then
    sec "OpenSIPS"
    ok "opensips ativo ($(opensips -V 2>/dev/null | awk 'NR == 1 { print $3 }'))"
    if mi version >/dev/null; then ok "MI responde (opensips-cli)"; else fail "MI sem resposta (opensips-cli -x mi version)"; fi
    if mi address_dump | grep -q "${GEN_IP}"; then
        ok "${GEN_IP} carregado na tabela address (liberado como operadora)"
    else
        warn "${GEN_IP} fora da tabela address carregada: esperado antes do 10-opensips-address-add.sql + address_reload (sem isso: 403)"
    fi
    mi lb_list | grep -E '"(uri|max|load)"' | sed 's/^ */        /' | head -12
    mi get_statistics active_dialogs shmem: | grep -E 'active_dialogs|used_size|free_size' | sed 's/^ */        /'
fi

sec "Coleta pelo usuario loadtest"
if id loadtest >/dev/null 2>&1; then ok "usuario loadtest existe"; else warn "usuario loadtest ausente (flux-host.sh prepare freeswitch [opensips])"; fi
sl=$(sudo -l -U loadtest 2>/dev/null)
if grep -q fs_cli <<< "${sl}"; then ok "loadtest pode rodar fs_cli com sudo -n"; else warn "loadtest sem sudo para fs_cli"; fi
if systemctl is-active --quiet opensips 2>/dev/null; then
    if grep -q opensips-cli <<< "${sl}"; then ok "loadtest pode rodar opensips-cli com sudo -n"; else warn "loadtest sem sudo para opensips-cli"; fi
fi

sec "Disco"
for d in /var/lib/freeswitch /var/log/freeswitch /var/log; do
    [[ -d ${d} ]] || continue
    use=$(df -P "${d}" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
    if ((use >= 85)); then fail "${d} com ${use}% usado (o guard para o teste com menos de 15% livre)"; else ok "${d}: ${use}% usado"; fi
done

sec "Firewall e bloqueios para ${GEN_IP}"
if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
    printf '        nftables: %s regra(s) citam %s\n' "$(nft list ruleset 2>/dev/null | grep -c "${GEN_IP}" || true)" "${GEN_IP}"
    nft list ruleset 2>/dev/null | grep -E 'policy drop' | sed 's/^/        /' | head -5
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -S 2>/dev/null | grep -E -- "-P (INPUT|OUTPUT)|${GEN_IP}" | sed 's/^/        /' | head -10
fi
if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client banned 2>/dev/null | grep -q "${GEN_IP}"; then
        fail "${GEN_IP} banido no fail2ban"
    else
        ok "${GEN_IP} nao esta banido no fail2ban (inclua em ignoreip antes do teste)"
    fi
fi
warn "Event Guard do Flux: confirme a whitelist de ${GEN_IP} na interface"

printf '\n'
((FAIL == 0)) && { echo "preflight $(hostname): sem falhas"; exit 0; }
echo "preflight $(hostname): ${FAIL} falha(s)"
exit 1
