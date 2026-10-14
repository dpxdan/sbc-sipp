#!/usr/bin/env bash
#
# Ponto de entrada comum dos servidores do laboratorio STFC.
# Define as senhas (do .env gerado pelo lab.sh), sobe o sshd e o papel do container.

set -Eeuo pipefail

log() { printf '[%(%H:%M:%S)T] %s: %s\n' -1 "$(hostname)" "$*"; }

: "${LAB_LOADTEST_PASSWORD:?defina no .env (lab.sh up gera)}"
: "${LAB_ADMIN_PASSWORD:?defina no .env (lab.sh up gera)}"

printf 'loadtest:%s\nadmin:%s\n' "${LAB_LOADTEST_PASSWORD}" "${LAB_ADMIN_PASSWORD}" | chpasswd
# Chaves de host unicas por servidor (as da imagem seriam iguais em todos os containers)
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
ssh-keygen -A >/dev/null
/usr/sbin/sshd
log "sshd ativo"

if [[ -n ${LAB_ROLE:-} && -x /opt/flux-lab/${LAB_ROLE}/start.sh ]]; then
    /opt/flux-lab/"${LAB_ROLE}"/start.sh
fi

log "pronto"
exec sleep infinity
