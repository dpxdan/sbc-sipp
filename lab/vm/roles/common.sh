#!/usr/bin/env bash
#
# Papel comum das 5 VMs do laboratorio: pacotes base, nome, /etc/hosts, relogio e o
# usuario loadtest (o "flux-loadtest.sh keys setup" entra nele por senha uma vez e
# instala a chave da VM de teste). Idempotente.
#
# role.env: LAB_HOSTNAME, LAB_SET_HOSTNAME, LAB_HOSTS (linhas "ip nome" separadas por ";"),
#           LAB_LOADTEST_PASSWORD

# shellcheck source=lab/vm/roles/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_debian12
load_role_env
need LAB_HOSTNAME LAB_HOSTS LAB_LOADTEST_PASSWORD

log "pacotes base"
apt-get update
apt_install openssh-server sudo iproute2 procps curl ca-certificates gnupg lsb-release less \
    netcat-openbsd systemd-timesyncd
systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || warn "systemd-timesyncd nao ativado (use NTP/chrony)"

if [[ ${LAB_SET_HOSTNAME:-1} == 1 && $(hostname) != "${LAB_HOSTNAME}" ]]; then
    hostnamectl set-hostname "${LAB_HOSTNAME}"
    log "hostname: ${LAB_HOSTNAME}"
fi

# Bloco gerenciado do /etc/hosts com os nomes do laboratorio
hosts_block() {
    printf '# flux-lab inicio (gerado pelo vmlab.sh)\n'
    tr ';' '\n' <<< "${LAB_HOSTS}" | awk 'NF == 2'
    printf '# flux-lab fim\n'
}
tmp=$(mktemp)
awk '/^# flux-lab inicio/ { skip = 1 } !skip { print } /^# flux-lab fim/ { skip = 0 }' /etc/hosts > "${tmp}"
hosts_block >> "${tmp}"
install -m 0644 "${tmp}" /etc/hosts
rm -f "${tmp}"

if ! id loadtest >/dev/null 2>&1; then
    useradd -m -s /bin/bash loadtest
    log "usuario loadtest criado"
fi
# senha pelo stdin do chpasswd (nao aparece na lista de processos)
printf 'loadtest:%s\n' "${LAB_LOADTEST_PASSWORD}" | chpasswd
install -d -m 0755 /etc/flux-lab
log "papel common pronto"
