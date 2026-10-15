#!/usr/bin/env bash
#
# Papel gen: o proprio servidor de testes (VM originadora). Pacotes do estagio "gen" do
# lab/images/Dockerfile, mais git/rsync para o vmlab.sh, diretorios do flux-loadtest e
# limites de rede e arquivos para o SIPp com RTP. Roda local (sem role.env). Idempotente.

# shellcheck source=lab/vm/roles/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_debian12

log "pacotes do servidor de testes"
apt-get update
apt_install sip-tester wrk sysbench default-mysql-client python3 openssh-client curl git \
    iproute2 procps ca-certificates less expect netbase
install -d -m 0750 /etc/flux-loadtest /var/lib/flux-loadtest/results

# Buffers UDP (SIP e RTP de milhares de chamadas) e arquivos abertos (SIPp: ~3 por chamada)
cat > /etc/sysctl.d/90-flux-loadtest.conf <<'EOF'
# gerado pelo lab/vm/roles/gen.sh (flux-loadtest)
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.netdev_max_backlog = 30000
net.ipv4.ip_local_port_range = 10000 65000
EOF
sysctl -q --system || warn "sysctl --system retornou erro (confira /etc/sysctl.d)"
cat > /etc/security/limits.d/90-flux-loadtest.conf <<'EOF'
# gerado pelo lab/vm/roles/gen.sh (flux-loadtest)
root    soft nofile 65536
root    hard nofile 65536
*       soft nofile 65536
*       hard nofile 65536
EOF
log "papel gen pronto: $(sipp -v 2>&1 | grep -o 'SIPp v[^ ]*' | head -1), $(wrk -v 2>&1 | head -1 | awk '{print $1, $2}')"
