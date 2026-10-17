#!/usr/bin/env bash
#
# preflight-165.sh - verificacao SOMENTE LEITURA do gerador (.165, sbc-stfc-interfaceweb) antes
# do teste de carga direto no FreeSWITCH do .162 (WEB-1437). Nada e alterado.
#
# Uso (root no .165):  bash preflight-165.sh [loadtest.conf]
# Saida: linhas "ok", "AVISO" e "FALHA"; codigo 1 se houver FALHA.

set -uo pipefail
export LC_ALL=C

CONF=${1:-/etc/flux-loadtest/loadtest.conf}
FS_PUB=200.159.177.162
FAIL=0

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  AVISO %s\n' "$*"; }
fail() { printf '  FALHA %s\n' "$*"; FAIL=$((FAIL + 1)); }
sec()  { printf -- '-- %s\n' "$*"; }

((EUID == 0)) || { echo "rode como root (portas, firewall, agent)"; exit 2; }

# Valor de uma chave do loadtest.conf (lido como dado)
cfg() { [[ -r ${CONF} ]] && awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); gsub(/^["\x27]|["\x27]$/, ""); v = $0 } END { print v }' "${CONF}"; }

tcp() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

printf '== %s\n' "$(hostname)"

sec "Sistema"
# shellcheck disable=SC1091
ver=$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-?}" "${VERSION_ID:-?}")
if [[ ${ver} == "debian 12" ]]; then ok "Debian 12"; else warn "sistema: ${ver} (validado em Debian 12)"; fi
printf '        %s vCPU, load %s, memoria disponivel %s MB\n' "$(nproc)" "$(cut -d' ' -f1-3 /proc/loadavg)" \
    "$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)"
for s in nginx php7.3-fpm; do
    systemctl is-active --quiet "${s}" && printf '        %s ativo (divide a CPU com o gerador: GUARD_MAX_GEN_CPU_PCT)\n' "${s}"
done

sec "Configuracao (${CONF})"
if [[ -r ${CONF} ]]; then ok "loadtest.conf legivel"; else warn "${CONF} ausente (copie deploy/stfc-fs02/loadtest.conf)"; fi
local_ip=$(cfg SIP_LOCAL_IP)
src=$(ip -o route get "${FS_PUB}" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
dev=$(ip -o route get "${FS_PUB}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
if [[ -n ${src} ]]; then
    ok "rota ate ${FS_PUB}: origem ${src} (interface ${dev})"
    if [[ -n ${local_ip} && ${local_ip} != "${src}" ]]; then
        warn "SIP_LOCAL_IP=${local_ip} difere da origem da rota (${src}): o .162 ve o IP de origem na ACL"
    fi
else
    fail "sem rota ate ${FS_PUB}"
fi
for k in DID_FILE FS_CLI_PASSWORD_FILE; do
    v=$(cfg "${k}")
    [[ -z ${v} ]] && continue
    if [[ -r ${v} ]]; then ok "${k}: ${v}"; else warn "${k}: ${v} ainda nao existe"; fi
done
if [[ -r $(cfg DID_FILE) ]]; then
    printf '        %s DID(s) em %s\n' "$(grep -cE '^\+?[0-9]{4,20}$' "$(cfg DID_FILE)")" "$(cfg DID_FILE)"
fi

sec "Ferramentas"
for b in sipp python3 ssh curl ss expect; do
    if command -v "${b}" >/dev/null 2>&1; then ok "${b}"; else warn "${b} ausente (flux-host.sh prepare gen)"; fi
done
command -v sipp >/dev/null 2>&1 && sipp -v 2>&1 | grep -o 'SIPp v[^ ]*' | head -1 | sed 's/^/        /'

sec "Portas locais (SIPp)"
for p in "$(cfg SIP_LOCAL_PORT)" "$(cfg UAS_PORT)"; do
    [[ -n ${p} ]] || continue
    if ss -Hlun "sport = :${p}" 2>/dev/null | grep -q .; then
        fail "porta ${p}/udp ja em uso: $(ss -Hlunp "sport = :${p}" | awk '{ print $NF }' | head -1)"
    else
        ok "porta ${p}/udp livre"
    fi
done

sec "Alcance (SSH da coleta e Zabbix)"
for h in 200.159.177.162 200.159.177.161 200.159.177.164; do
    if tcp "${h}" "$(cfg SSH_PORT || true)" || tcp "${h}" 22; then ok "SSH ${h}"; else fail "SSH ${h} inacessivel"; fi
done
zs=$(cfg ZABBIX_SERVER)
if [[ -n ${zs} ]]; then
    if tcp "${zs}" "$(cfg ZABBIX_PORT)"; then ok "trapper ${zs}:$(cfg ZABBIX_PORT)"; else fail "trapper ${zs}:$(cfg ZABBIX_PORT) inacessivel"; fi
else
    warn "ZABBIX_SERVER vazio no loadtest.conf"
fi

sec "Firewall de entrada (atendedor: UAS_PORT e RTP vindos do .162)"
if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
    nft list ruleset 2>/dev/null | grep -E "policy drop|${FS_PUB}|$(cfg UAS_PORT)" | sed 's/^/        /' | head -10
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -S INPUT 2>/dev/null | grep -E -- "-P INPUT|${FS_PUB}|$(cfg UAS_PORT)" | sed 's/^/        /' | head -10
fi
warn "com politica drop: liberar do ${FS_PUB} $(cfg SIP_LOCAL_PORT)/udp e $(cfg UAS_PORT)/udp, e o RTP a partir de $(cfg RTP_PORT_BASE)/udp (originador) e $(cfg UAS_RTP_PORT_BASE)/udp (atendedor), 2 portas por chamada"

sec "zabbix-agent (disparo pelo Zabbix)"
if dpkg -s zabbix-agent >/dev/null 2>&1; then
    ok "zabbix-agent $(dpkg-query -W -f '${Version}' zabbix-agent)"
    if systemctl is-active --quiet zabbix-agent; then ok "servico ativo"; else fail "zabbix-agent inativo"; fi
    for f in /etc/zabbix/zabbix_agentd.conf /etc/zabbix/zabbix_agentd.d/*.conf; do
        [[ -r ${f} ]] || continue
        grep -HE '^[[:space:]]*(Server|ServerActive|Include|AllowKey|DenyKey|EnableRemoteCommands)=' "${f}" | sed 's/^/        /'
    done
    if grep -hqE '^[[:space:]]*AllowKey=system\.run\[\*\]' /etc/zabbix/zabbix_agentd.conf /etc/zabbix/zabbix_agentd.d/*.conf 2>/dev/null; then
        warn "AllowKey=system.run[*] ja existe: a restricao por perfil do disparo nao teria efeito"
    fi
elif dpkg -s zabbix-agent2 >/dev/null 2>&1; then
    fail "zabbix-agent2 instalado: o papel zabbix-agent do flux-host.sh e para o agentd"
else
    warn "sem zabbix-agent"
fi

printf '\n'
((FAIL == 0)) && { echo "preflight .165: sem falhas"; exit 0; }
echo "preflight .165: ${FAIL} falha(s)"
exit 1
