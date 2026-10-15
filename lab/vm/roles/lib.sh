# shellcheck shell=bash
#
# lab/vm/roles/lib.sh - funcoes comuns dos papeis do laboratorio em VMs Debian 12.
# Carregado pelos papeis (common, db, web, sbc, gen); roda como root na VM.

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

readonly ROLE_ENV=/etc/flux-lab/role.env
# Raiz enviada pelo vmlab.sh (/opt/flux-lab): vm/roles e os modelos de images/
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034  # usado pelos papeis que carregam este arquivo
readonly LAB_ROOT

log()  { printf '[%(%H:%M:%S)T] %s: %s\n' -1 "$(hostname)" "$*"; }
warn() { log "AVISO: $*" >&2; }
die()  { log "ERRO: $*" >&2; exit 1; }

trap 'printf "[%s] falha na linha %s: %s\n" "${0##*/}" "${LINENO}" "${BASH_COMMAND}" >&2' ERR

require_root() {
    ((EUID == 0)) || die "rode como root (o vmlab.sh usa sudo)"
}

require_debian12() {
    local id="" ver=""
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && { id=$(. /etc/os-release && printf '%s' "${ID}"); ver=$(. /etc/os-release && printf '%s' "${VERSION_ID}"); }
    [[ ${id} == debian && ${ver} == 12 ]] || die "Debian 12 necessario (encontrado: ${id:-?} ${ver:-?})"
}

# Variaveis do papel, gravadas pelo vmlab.sh (0600, valores com printf %q)
load_role_env() {
    [[ -r ${ROLE_ENV} ]] || die "${ROLE_ENV} ausente (o vmlab.sh grava antes de rodar o papel)"
    set -a
    # shellcheck disable=SC1090
    . "${ROLE_ENV}"
    set +a
}

need() {
    local v
    for v in "$@"; do
        [[ -n ${!v:-} ]] || die "${v} nao definido em ${ROLE_ENV}"
    done
}

apt_install() {
    apt-get install -y --no-install-recommends "$@"
}

# Repositorio sury (PHP 7.3, como em producao)
add_sury_php() {
    [[ -f /etc/apt/sources.list.d/sury-php.list ]] && return 0
    local tmp
    tmp=$(mktemp -d)
    curl -fsSLo "${tmp}/keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb
    apt-get install -y "${tmp}/keyring.deb"
    rm -rf "${tmp}"
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ bookworm main" \
        > /etc/apt/sources.list.d/sury-php.list
    apt-get update
}

# Espera uma porta TCP local ou remota (host porta segundos)
wait_tcp() {
    local host=$1 port=$2 secs=${3:-60} i
    for ((i = 0; i < secs; i++)); do
        (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# Interface que tem o IP informado
iface_of() {
    ip -o -4 addr show | awk -v a="$1/" 'index($4, a) == 1 { print $2; exit }'
}
