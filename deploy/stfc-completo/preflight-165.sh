#!/usr/bin/env bash
#
# preflight-165.sh - verificacao SOMENTE LEITURA do gerador (.165, sbc-stfc-interfaceweb) antes
# do teste de carga completo pelo OpenSIPS (WEB-1437). Nada e alterado. Os alvos vem do
# loadtest.conf (SIP_TARGET, OPENSIPS_HOST, FS_HOSTS, DB_HOSTS).
#
# Uso (root no .165):  bash preflight-165.sh [loadtest.conf]
# Saida: linhas "ok", "AVISO" e "FALHA"; codigo 1 se houver FALHA.

set -uo pipefail
export LC_ALL=C

CONF=${1:-/etc/flux-loadtest/loadtest.conf}
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
if [[ -r ${CONF} ]]; then ok "loadtest.conf legivel"; else fail "${CONF} ausente (copie deploy/stfc-completo/loadtest.conf)"; fi
local_ip=$(cfg SIP_LOCAL_IP)
target=$(cfg SIP_TARGET)
target=${target%%:*}
FS_LIST=$(cfg FS_HOSTS)
src=$(ip -o route get "${target}" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
dev=$(ip -o route get "${target}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
if [[ -n ${src} ]]; then
    ok "rota ate o OpenSIPS ${target}: origem ${src} (interface ${dev})"
    if [[ -n ${local_ip} && ${local_ip} != "${src}" ]]; then
        warn "SIP_LOCAL_IP=${local_ip} difere da origem da rota (${src}): o OpenSIPS ve o IP de origem na tabela address"
    fi
else
    fail "sem rota ate ${target}"
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
# OpenSIPS, FS e bancos, sem repetir o sbc-stfc-1 (OpenSIPS e FS no mesmo servidor)
read -ra hosts <<< "$(cfg OPENSIPS_HOST) ${FS_LIST} $(cfg DB_HOSTS)"
mapfile -t hosts < <(printf '%s\n' "${hosts[@]}" | awk 'NF && !seen[$0]++')
for h in "${hosts[@]}"; do
    if tcp "${h}" "$(cfg SSH_PORT || true)" || tcp "${h}" 22; then ok "SSH ${h}"; else fail "SSH ${h} inacessivel"; fi
done
zs=$(cfg ZABBIX_SERVER)
if [[ -n ${zs} ]]; then
    if tcp "${zs}" "$(cfg ZABBIX_PORT)"; then ok "trapper ${zs}:$(cfg ZABBIX_PORT)"; else fail "trapper ${zs}:$(cfg ZABBIX_PORT) inacessivel"; fi
else
    ok "sem Zabbix neste teste (ZABBIX_SERVER vazio)"
fi

sec "Firewall de entrada (respostas do OpenSIPS; bridge e RTP vindos dos FS)"
if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
    nft list ruleset 2>/dev/null | grep -E "policy drop|$(cfg UAS_PORT)" | sed 's/^/        /' | head -10
fi
if command -v iptables >/dev/null 2>&1; then
    iptables -S INPUT 2>/dev/null | grep -E -- "-P INPUT|$(cfg UAS_PORT)" | sed 's/^/        /' | head -10
fi
srcs=$(printf '%s\n' "${target}" ${FS_LIST} | awk 'NF && !seen[$0]++' | paste -sd ' ' -)
warn "com politica drop: liberar de ${srcs}: $(cfg SIP_LOCAL_PORT)/udp, $(cfg UAS_PORT)/udp e o RTP a partir de $(cfg RTP_PORT_BASE)/udp (originador) e $(cfg UAS_RTP_PORT_BASE)/udp (atendedor), 2 portas por chamada simultanea em cada faixa"

printf '\n'
((FAIL == 0)) && { echo "preflight .165: sem falhas"; exit 0; }
echo "preflight .165: ${FAIL} falha(s)"
exit 1
