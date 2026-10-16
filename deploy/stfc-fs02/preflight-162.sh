#!/usr/bin/env bash
#
# preflight-162.sh - verificacao SOMENTE LEITURA do sbc-stfc-02 (.162) antes do teste de carga
# direto no FreeSWITCH a partir do gerador .165 (WEB-1437). Nada e alterado.
#
# Uso (root no .162):  bash preflight-162.sh [IP_DO_GERADOR]
# Saida: linhas "ok", "AVISO" e "FALHA"; codigo 1 se houver FALHA.

set -uo pipefail
export LC_ALL=C

GEN_IP=${1:-200.159.177.165}
FS_PUB=200.159.177.162
FAIL=0

ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  AVISO %s\n' "$*"; }
fail() { printf '  FALHA %s\n' "$*"; FAIL=$((FAIL + 1)); }
sec()  { printf -- '-- %s\n' "$*"; }

[[ ${GEN_IP} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "uso: $0 [IP_DO_GERADOR]"; exit 2; }
((EUID == 0)) || { echo "rode como root (fs_cli, sudo -l, firewall)"; exit 2; }

fsx() { timeout 10 fs_cli -x "$1" 2>/dev/null; }

printf '== %s (%s), gerador %s\n' "$(hostname)" "${FS_PUB}" "${GEN_IP}"

sec "FreeSWITCH"
if systemctl is-active --quiet freeswitch; then ok "servico freeswitch ativo"; else fail "freeswitch inativo"; fi
st=$(fsx status)
if [[ -n ${st} ]]; then
    ok "fs_cli responde (root)"
    printf '%s\n' "${st}" | sed -n '/session(s)/p;/max sessions\|session(s) per Sec/p' | sed 's/^/        /'
    sps=$(printf '%s\n' "${st}" | sed -n 's/.*out of max \([0-9]*\).*per Sec.*/\1/p' | head -1)
    [[ -n ${sps} ]] && warn "sessions-per-second=${sps}: com bridge para o atendedor cada chamada abre 2 sessoes (teto ~$((sps / 2)) CPS)"
else
    fail "fs_cli sem resposta como root (/root/.fs_cli_conf ou senha do event socket)"
fi
ch=$(fsx 'show channels count' | awk '/total/ { print $1 }')
[[ -n ${ch} ]] && ok "canais em uso agora: ${ch} (trafego real no mesmo FS)"

sec "Perfil SIP default (alvo ${FS_PUB}:5070)"
prof=$(fsx 'sofia status profile default')
if printf '%s\n' "${prof}" | grep -q "${FS_PUB}:5070"; then
    ok "perfil default em ${FS_PUB}:5070"
else
    fail "perfil default nao aparece em ${FS_PUB}:5070 (confira 'sofia status')"
fi
printf '%s\n' "${prof}" | grep -E '^(BIND-URL|SIP-IP|RTP-IP|EXT-RTP-IP|STATE|CALLS-IN|FAILED-CALLS-IN)' | sed 's/^/        /'

sec "ACL (lista default, servida pelo xml_curl)"
acl=$(fsx "acl ${GEN_IP} default")
case "${acl}" in
    true)  ok "${GEN_IP} ja autorizado na ACL default" ;;
    false) warn "${GEN_IP} fora da ACL default: esperado antes do 10-acl-lb-add.sql + reloadacl (sem isso: 403)" ;;
    *)     fail "nao foi possivel consultar a ACL (fs_cli -x 'acl ${GEN_IP} default')" ;;
esac
found=""
for f in /var/www/html/fs/lib/flux.xml.php /opt/flux/freeswitch/fs/lib/flux.xml.php /usr/share/flux/freeswitch/fs/lib/flux.xml.php; do
    [[ -r ${f} ]] && grep -q acl_lb_networks "${f}" && found=${f}
done
if [[ -n ${found} ]]; then
    ok "xml_curl com suporte a acl_lb_networks (${found})"
else
    fail "flux.xml.php sem acl_lb_networks (ou em outro caminho): a liberacao por 10-acl-lb-add.sql nao teria efeito"
fi

sec "Limites e RTP (switch.conf)"
sw=/etc/freeswitch/autoload_configs/switch.conf.xml
if [[ -r ${sw} ]]; then
    grep -oE 'name="(max-sessions|sessions-per-second|rtp-start-port|rtp-end-port)" value="[^"]*"' "${sw}" | sed 's/^/        /'
else
    warn "${sw} nao encontrado"
fi

sec "Coleta pelo usuario loadtest"
if id loadtest >/dev/null 2>&1; then ok "usuario loadtest existe"; else warn "usuario loadtest ausente (flux-host.sh prepare freeswitch)"; fi
if sudo -l -U loadtest 2>/dev/null | grep -q fs_cli; then
    ok "loadtest pode rodar fs_cli com sudo -n"
else
    warn "loadtest sem sudo para fs_cli (flux-host.sh prepare freeswitch)"
fi

sec "Disco"
for d in /var/lib/freeswitch /var/log/freeswitch; do
    [[ -d ${d} ]] || continue
    use=$(df -P "${d}" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
    if ((use >= 85)); then fail "${d} com ${use}% usado (guard para o teste com menos de 15% livre)"; else ok "${d}: ${use}% usado"; fi
done

sec "Firewall e bloqueios para ${GEN_IP}"
if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
    n=$(nft list ruleset 2>/dev/null | grep -c "${GEN_IP}" || true)
    printf '        nftables: %s regra(s) citam %s\n' "${n}" "${GEN_IP}"
    nft list ruleset 2>/dev/null | grep -E 'policy drop|5070' | sed 's/^/        /' | head -10
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -S 2>/dev/null | grep -E -- "-P INPUT|${GEN_IP}|5070" | sed 's/^/        /' | head -15
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
((FAIL == 0)) && { echo "preflight .162: sem falhas"; exit 0; }
echo "preflight .162: ${FAIL} falha(s)"
exit 1
