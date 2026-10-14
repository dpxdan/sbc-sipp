#!/usr/bin/env bash
#
# lab.sh - laboratorio STFC do flux-loadtest em Docker (WEB-1437)
#
# Sobe 6 containers Debian 12 com os mesmos nomes, papeis e finais de IP do
# ambiente STFC: OpenSIPS/FreeSWITCH simulados (SIPp), Percona XtraDB Cluster
# 8.4.10 real com keepalived, nginx 1.22.1 + PHP-FPM 7.3.33 reais e a VM de teste.
#
# Uso: ./lab.sh up|conf|status|shell|interna|externa|down [opcoes]

set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR
readonly ENV_FILE="${LAB_DIR}/.env"
readonly OUT_DIR="${LAB_DIR}/out"
readonly COMPOSE=(docker compose -f "${LAB_DIR}/docker-compose.yml" --project-directory "${LAB_DIR}")

log()  { printf '[lab] %s\n' "$*"; }
warn() { printf '[lab] AVISO: %s\n' "$*" >&2; }
die()  { printf '[lab] ERRO: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Uso: $0 <acao> [opcoes]

  up                    gera o .env (senhas aleatorias), constroi e sobe o laboratorio,
                        espera o cluster e gera a configuracao do flux-loadtest
  conf [--dids ARQ]     (re)gera out/loadtest.conf, out/dids.txt e os arquivos de senha;
                        sem --dids, gera 100 mil DIDs ficticios
  status                containers, estado do Percona XtraDB Cluster e no do VIP
  keys                  roda "flux-loadtest.sh keys setup" na vm-teste respondendo a senha do
                        usuario loadtest de cada servidor (expect; senha so do laboratorio)
  shell                 abre um shell na vm-teste (onde o flux-loadtest roda)
  interna | externa     liga/desliga a vm-teste da rede interna (necessario para --tests mysql)
  down                  remove os containers e as redes (dados do laboratorio sao efemeros)

Dentro da vm-teste:
  cd /opt/flux-loadtest && ./flux-loadtest.sh check -c /etc/flux-loadtest/loadtest.conf
EOF
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker nao encontrado"
    docker info >/dev/null 2>&1 || die "Docker nao esta em execucao (abra o Docker Desktop)"
    docker compose version >/dev/null 2>&1 || die "docker compose indisponivel"
}

rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

ensure_env() {
    if [[ -f ${ENV_FILE} ]]; then
        return 0
    fi
    umask 077
    {
        printf '# Gerado pelo lab.sh: senhas do laboratorio (nao versionar)\n'
        printf 'LAB_LOADTEST_PASSWORD=%s\n' "$(rand)"
        printf 'LAB_ADMIN_PASSWORD=%s\n' "$(rand)"
        printf 'LAB_MYSQL_ROOT_PASSWORD=%s\n' "$(rand)"
        printf 'LAB_MONITOR_PASSWORD=%s\n' "$(rand)"
        printf 'LAB_BENCH_PASSWORD=%s\n' "$(rand)"
        printf 'LAB_WEB_DB_PASSWORD=%s\n' "$(rand)"
        printf 'LAB_FS_CLI_PASSWORD=%s\n' "$(rand)"
        printf 'LAB_VM_MAX_SECONDS=120\n'
    } > "${ENV_FILE}"
    log ".env criado com senhas aleatorias (${ENV_FILE})"
}

env_get() {
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${ENV_FILE}"
}

cmd_conf() {
    local dids_src=""
    while (($# > 0)); do
        case "$1" in
            --dids) dids_src=${2:-}; shift 2 ;;
            *) die "opcao invalida para conf: $1" ;;
        esac
    done
    [[ -f ${ENV_FILE} ]] || die ".env ausente; rode '$0 up'"
    install -d -m 0700 "${OUT_DIR}" "${OUT_DIR}/results"

    if [[ -n ${dids_src} ]]; then
        [[ -r ${dids_src} ]] || die "arquivo de DIDs ilegivel: ${dids_src}"
        # aceita lista simples ou o CSV "id;number;..." (usa a coluna number)
        awk -F';' 'NR == 1 && $2 == "number" { next } { n = (NF > 1) ? $2 : $1; gsub(/\r/, "", n); if (n ~ /^\+?[0-9]{4,20}$/) print n }' \
            "${dids_src}" > "${OUT_DIR}/dids.txt"
        log "DIDs copiados de ${dids_src}: $(wc -l < "${OUT_DIR}/dids.txt" | tr -d ' ')"
    else
        {
            printf '# DIDs ficticios do laboratorio (gerados pelo lab.sh)\n'
            awk 'BEGIN { for (i = 0; i < 100000; i++) printf "55519%08d\n", i }'
        } > "${OUT_DIR}/dids.txt"
        log "100000 DIDs ficticios gerados"
    fi

    umask 077
    env_get LAB_FS_CLI_PASSWORD > "${OUT_DIR}/fs_cli.pass"
    env_get LAB_BENCH_PASSWORD > "${OUT_DIR}/mysql_bench.pass"
    env_get LAB_LOADTEST_PASSWORD > "${OUT_DIR}/loadtest.pass"

    cat > "${OUT_DIR}/loadtest.conf" <<'CONF'
# flux-loadtest - laboratorio STFC em Docker (gerado pelo lab.sh)
# Redes: interna 172.30.4.0/24 (= 172.17.4.0/24) e "publica" 172.30.177.0/24 (= 200.159.177.x)
SSH_USER=loadtest
SSH_KEY=/etc/flux-loadtest/id_ed25519
SSH_PORT=22
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes"
SSH_KNOWN_HOSTS=/etc/flux-loadtest/known_hosts

OPENSIPS_HOST=172.30.177.163
FS_HOSTS="172.30.177.163 172.30.177.162"
DB_HOSTS="172.30.177.161 172.30.177.164"
WEB_HOST=172.30.177.165

SIP_TARGET=172.30.177.163:5060
DID_FILE=/etc/flux-loadtest/dids.txt
CALLER_ID=551130009999

FS_CLI_CMD="sudo -n fs_cli -x"
FS_CLI_PASSWORD_FILE=/etc/flux-loadtest/fs_cli.pass
OPENSIPS_MI_CMD="sudo -n opensips-cli -x mi"
MYSQL_CLI_CMD="mysql --defaults-extra-file=/etc/mysql/flux-loadtest.cnf"
DB_VIP=172.30.4.100

NGINX_STATUS_URL=http://127.0.0.1/nginx_status
FPM_STATUS_URL=http://127.0.0.1/fpm-status?json
WEB_BASE_URL=https://172.30.177.165

MYSQL_BENCH_HOST=172.30.4.100
MYSQL_BENCH_USER=flux_bench
MYSQL_BENCH_PASSWORD_FILE=/etc/flux-loadtest/mysql_bench.pass
MYSQL_BENCH_TABLES=2
MYSQL_BENCH_TABLE_SIZE=20000
MYSQL_BENCH_THREADS=4

GUARD_MIN_WSREP_CLUSTER_SIZE=2
SAMPLE_INTERVAL=5
BASELINE_SECONDS=20
COOLDOWN_SECONDS=20
RESULTS_DIR=/var/lib/flux-loadtest/results
CONF
    log "configuracao gerada em ${OUT_DIR}/loadtest.conf (na vm-teste: /etc/flux-loadtest/loadtest.conf)"
}

wait_cluster() {
    local i size=""
    log "aguardando o Percona XtraDB Cluster formar (2 nos)"
    for ((i = 0; i < 240; i++)); do
        size=$("${COMPOSE[@]}" exec -T banco-master-sbc-stfc \
            mysql --defaults-extra-file=/etc/mysql/flux-loadtest.cnf -N -B \
            -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '{ print $2 }') || true
        if [[ ${size} == 2 ]]; then
            log "cluster com 2 nos"
            return 0
        fi
        sleep 2
    done
    warn "cluster nao chegou a 2 nos em 8 min (tamanho atual: ${size:-?}); veja: $0 status"
}

cmd_up() {
    require_docker
    ensure_env
    install -d -m 0700 "${OUT_DIR}" "${OUT_DIR}/results"
    # Os servidores geram chaves de host novas a cada subida: a confianca anterior nao vale
    rm -f "${OUT_DIR}/known_hosts"
    log "construindo e subindo (a primeira vez baixa pacotes e leva alguns minutos)"
    "${COMPOSE[@]}" up -d --build
    wait_cluster
    [[ -f ${OUT_DIR}/loadtest.conf ]] || cmd_conf
    cmd_status
    cat <<EOF

Proximos passos:
  $0 keys
  $0 shell
  cd /opt/flux-loadtest
  ./flux-loadtest.sh check -c /etc/flux-loadtest/loadtest.conf
EOF
}

cmd_status() {
    require_docker
    "${COMPOSE[@]}" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
    local node
    for node in banco-master-sbc-stfc banco-slave-stfc; do
        printf '\n%s:\n' "${node}"
        "${COMPOSE[@]}" exec -T "${node}" bash -c \
            "mysql --defaults-extra-file=/etc/mysql/flux-loadtest.cnf -N -B -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment')\" 2>/dev/null | sed 's/^/  /'; printf '  sessoes em flux.ci_sessions: '; mysql -u labcheck -N -B -e 'SELECT COUNT(*) FROM flux.ci_sessions' 2>/dev/null || echo '?'; ip -o -4 addr show | grep -q ' 172.30.4.100/' && echo '  VIP 172.30.4.100: neste no' || echo '  VIP 172.30.4.100: em outro no'" \
            || warn "${node} indisponivel"
    done
}

cmd_net() {
    require_docker
    local net="flux-stfc-lab_stfc_int"
    if [[ $1 == interna ]]; then
        docker network connect --ip 172.30.4.50 "${net}" flux-stfc-lab-vm-teste-1 \
            && log "vm-teste ligada a rede interna (172.30.4.50): o VIP fica acessivel"
    else
        docker network disconnect "${net}" flux-stfc-lab-vm-teste-1 \
            && log "vm-teste desligada da rede interna"
    fi
}

cmd_keys() {
    require_docker
    [[ -f ${OUT_DIR}/loadtest.conf ]] || die "configuracao ausente; rode '$0 up'"
    "${COMPOSE[@]}" exec -T vm-teste expect -f /opt/flux-loadtest/lab/images/gen/keys-setup.exp
}

main() {
    local action=${1:-}
    (($# > 0)) && shift
    case "${action}" in
        up)              cmd_up ;;
        conf)            cmd_conf "$@" ;;
        status)          cmd_status ;;
        keys)            cmd_keys ;;
        shell)           require_docker; exec "${COMPOSE[@]}" exec vm-teste bash ;;
        interna|externa) cmd_net "${action}" ;;
        down)            require_docker; "${COMPOSE[@]}" down --remove-orphans ;;
        ""|-h|--help)    usage ;;
        *)               usage >&2; die "acao invalida: ${action}" ;;
    esac
}

main "$@"
