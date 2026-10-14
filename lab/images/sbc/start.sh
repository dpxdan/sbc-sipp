#!/usr/bin/env bash
#
# Servidores SIP simulados com SIPp (UAS):
#   opensips -> porta 5060 (processo "opensips")
#   fs       -> porta 5070 (processo "freeswitch")
# O UAS atende como a caixa postal (100, 180, 200 com SDP) e desliga apos
# LAB_VM_MAX_SECONDS se a VM de teste nao enviar o BYE antes.
# As estatisticas do SIPp alimentam o fs_cli e o opensips-cli simulados.

set -Eeuo pipefail

log() { printf '[%(%H:%M:%S)T] %s: %s\n' -1 "$(hostname)" "$*"; }

: "${LAB_PUB_IP:?LAB_PUB_IP nao definido}"
: "${LAB_FS_CLI_PASSWORD:?defina no .env}"
LAB_SIP_ROLES=${LAB_SIP_ROLES:-fs}
LAB_VM_MAX_SECONDS=${LAB_VM_MAX_SECONDS:-120}
[[ ${LAB_VM_MAX_SECONDS} =~ ^[0-9]+$ ]] || { echo "LAB_VM_MAX_SECONDS invalido" >&2; exit 2; }

# senha do event socket exigida pelo fs_cli simulado
install -m 0600 /dev/null /etc/flux-lab/fs_cli.pass
printf '%s\n' "${LAB_FS_CLI_PASSWORD}" > /etc/flux-lab/fs_cli.pass

sed "s|@VM_MAX_MS@|$((LAB_VM_MAX_SECONDS * 1000))|" /opt/flux-lab/sbc/uas.xml.in > /run/flux-lab/uas.xml

start_uas() {
    local name=$1 port=$2 media=$3
    # -bg: o SIPp vai para segundo plano; o nome do executavel define o processo
    "/usr/local/sbin/${name}" -sf /run/flux-lab/uas.xml -i "${LAB_PUB_IP}" -p "${port}" -mp "${media}" \
        -nostdin -bg -trace_stat -stf "/run/flux-lab/${name}.csv" -fd 1 \
        -trace_err -error_file "/run/flux-lab/${name}-errors.log" >/dev/null 2>&1 || true
    log "${name} simulado em ${LAB_PUB_IP}:${port}"
}

for role in ${LAB_SIP_ROLES}; do
    case "${role}" in
        opensips) start_uas opensips 5060 30000 ;;
        fs)       start_uas freeswitch 5070 32000 ;;
        *)        log "papel SIP desconhecido: ${role}" ;;
    esac
done
date +%s > /run/flux-lab/started
