#!/usr/bin/env bash
#
# lab.sh - laboratorio STFC do flux-loadtest em Docker (WEB-1437)
#
# Sobe 6 containers Debian 12 com os mesmos nomes, papeis e finais de IP do
# ambiente STFC: OpenSIPS 3.6 + FreeSWITCH 1.11.3 reais com os scripts do Flux
# (ou simulados com SIPp, LAB_SBC_TARGET=sbc), Percona XtraDB Cluster 8.4.10 real
# com keepalived, nginx 1.22.1 + PHP-FPM 7.3.33 reais e a VM de teste.
# Mais o Zabbix (server, web e PostgreSQL) que recebe as amostras do flux-loadtest.
#
# Uso: ./lab.sh up|conf|status|keys|flux|zabbix|devices|shell|interna|externa|down [opcoes]

set -Eeuo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_DIR
readonly ENV_FILE="${LAB_DIR}/.env"
readonly OUT_DIR="${LAB_DIR}/out"
readonly COMPOSE=(docker compose -f "${LAB_DIR}/docker-compose.yml" --project-directory "${LAB_DIR}")
# Atendedor do teste de carga (SIPp UAS do flux-loadtest na vm-teste): destino dos DIDs
# DIRECT-IP 55519xxxxxxxx. IP fixo da vm-teste no docker-compose.yml.
readonly LAB_UAS_PORT=5090
readonly LAB_UAS_ADDR="172.30.177.50:${LAB_UAS_PORT}"

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
  status                containers, estado do Percona XtraDB Cluster e no do VIP, enderecos
                        de acesso pelo macOS
  keys                  roda "flux-loadtest.sh keys setup" na vm-teste respondendo a senha do
                        usuario loadtest de cada servidor (expect; senha so do laboratorio)
  flux                  carrega o schema do Flux no cluster (so na primeira vez), cria o fluxuser
                        e grava os dados do laboratorio: ramais, perfis SIP, DIDs, OpenSIPS
                        (o up ja faz isso)
  zabbix                troca a senha inicial do Admin do Zabbix, cria o token de API, importa
                        os templates e cria os hosts (o up ja faz isso)
  devices               ramais para registrar SIP devices no macOS (usuario, senha, servidor)
  shell                 abre um shell na vm-teste (onde o flux-loadtest roda)
  interna | externa     liga/desliga a vm-teste da rede interna (necessario para --tests mysql)
  down [--zabbix]       remove os containers e as redes (dados do laboratorio sao efemeros);
                        --zabbix apaga tambem o historico do Zabbix (volume zbx-db da versao
                        LAB_ZABBIX_VERSION, padrao 7.2.3 = producao)

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

# Acrescenta CHAVE=valor ao .env se ausente (migra .env de versoes anteriores do laboratorio)
env_add() {
    grep -q "^$1=" "${ENV_FILE}" 2>/dev/null || printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"
}

ensure_env() {
    local created=0
    if [[ ! -f ${ENV_FILE} ]]; then
        (umask 077 && printf '# Gerado pelo lab.sh: senhas do laboratorio (nao versionar)\n' > "${ENV_FILE}")
        created=1
    fi
    env_add LAB_LOADTEST_PASSWORD "$(rand)"
    env_add LAB_ADMIN_PASSWORD "$(rand)"
    env_add LAB_MYSQL_ROOT_PASSWORD "$(rand)"
    env_add LAB_MONITOR_PASSWORD "$(rand)"
    env_add LAB_BENCH_PASSWORD "$(rand)"
    env_add LAB_WEB_DB_PASSWORD "$(rand)"
    env_add LAB_FS_CLI_PASSWORD "$(rand)"
    env_add LAB_VM_MAX_SECONDS 120
    env_add LAB_ZBX_DB_PASSWORD "$(rand)"
    env_add LAB_ZBX_ADMIN_PASSWORD "$(rand)"
    env_add LAB_FLUX_DB_PASSWORD "$(rand)"
    # clone do repositorio sbc (scripts do Flux) e token da SignalWire (fora do repositorio)
    env_add LAB_FLUX_SRC "${HOME}/Desenvolvedor/Flux/Repositorio/dpxdan/sbc"
    # scripts Lua do FreeSWITCH: snapshot de producao (sbc01)
    env_add LAB_FLUX_SCRIPTS "${HOME}/Desenvolvedor/Flux/Servidores/flux-sbcbr/sbc01/freeswitch/scripts"
    env_add LAB_SIGNALWIRE_TOKEN_FILE "${HOME}/.config/flux-lab/signalwire.token"
    env_add LAB_SIP_DEVICES 20
    env_add LAB_DIDS 100000
    ((created)) && log ".env criado com senhas aleatorias (${ENV_FILE})"
    return 0
}

# Porta publicada no macOS: valor do .env ou o padrao do docker-compose.yml
port() {
    local v
    v=$(env_get "$1")
    printf '%s' "${v:-$2}"
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

    write_secrets

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
    uas_conf >> "${OUT_DIR}/loadtest.conf"
    zabbix_conf >> "${OUT_DIR}/loadtest.conf"
    log "configuracao gerada em ${OUT_DIR}/loadtest.conf (na vm-teste: /etc/flux-loadtest/loadtest.conf)"
}

write_secrets() {
    (
        umask 077
        env_get LAB_FS_CLI_PASSWORD > "${OUT_DIR}/fs_cli.pass"
        env_get LAB_BENCH_PASSWORD > "${OUT_DIR}/mysql_bench.pass"
        env_get LAB_LOADTEST_PASSWORD > "${OUT_DIR}/loadtest.pass"
        env_get LAB_ZBX_ADMIN_PASSWORD > "${OUT_DIR}/zabbix_admin.pass"
    )
}

zabbix_conf() {
    cat <<'CONF'

# Zabbix do laboratorio (zabbix-server 172.30.177.10, zabbix-web 172.30.177.11)
ZABBIX_SERVER=172.30.177.10
ZABBIX_PORT=10051
ZABBIX_HOST_PREFIX=lab-
ZABBIX_LIVE=1
ZABBIX_API_URL=http://172.30.177.11:8080/api_jsonrpc.php
ZABBIX_API_TOKEN_FILE=/etc/flux-loadtest/zabbix_api.token
CONF
}

# Configuracao gerada por versao anterior do lab.sh: acrescenta o bloco do Zabbix
# SBC real: os DIDs do teste sao DIRECT-IP para o atendedor da vm-teste.
# SBC simulado (LAB_SBC_TARGET=sbc): o proprio SIPp do sbc atende; sem atendedor.
uas_conf() {
    printf '\n# Atendedor na vm-teste (DIDs 55519xxxxxxxx DIRECT-IP para %s)\n' "${LAB_UAS_ADDR}"
    if [[ $(sbc_target) == sbc-real ]]; then
        printf 'UAS_PORT=%s\n' "${LAB_UAS_PORT}"
    else
        printf 'UAS_PORT=\n'
    fi
}

migrate_conf() {
    [[ -f ${OUT_DIR}/loadtest.conf ]] || return 0
    if ! grep -q '^UAS_PORT=' "${OUT_DIR}/loadtest.conf"; then
        uas_conf >> "${OUT_DIR}/loadtest.conf"
        log "UAS_PORT acrescentado a ${OUT_DIR}/loadtest.conf"
    fi
    if ! grep -q '^ZABBIX_SERVER=' "${OUT_DIR}/loadtest.conf"; then
        zabbix_conf >> "${OUT_DIR}/loadtest.conf"
        log "bloco do Zabbix acrescentado a ${OUT_DIR}/loadtest.conf"
    fi
}

wait_cluster() {
    local i size="" state=""
    log "aguardando o Percona XtraDB Cluster formar (2 nos, Synced)"
    for ((i = 0; i < 240; i++)); do
        # tamanho 2 ja aparece durante o SST (doador em Donor/Desynced): espera os dois Synced
        read -r size state < <("${COMPOSE[@]}" exec -T banco-slave-stfc \
            mysql --defaults-extra-file=/etc/mysql/flux-loadtest.cnf -N -B \
            -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_local_state_comment')" 2>/dev/null \
            | awk '{ v[$1] = $2 } END { print v["wsrep_cluster_size"], v["wsrep_local_state_comment"] }') || true
        if [[ ${size} == 2 && ${state} == Synced ]]; then
            log "cluster com 2 nos, banco-slave-stfc Synced"
            return 0
        fi
        sleep 2
    done
    warn "cluster nao ficou pronto em 8 min (tamanho ${size:-?}, estado ${state:-?}); veja: $0 status"
}

sbc_target() {
    local t
    t=$(env_get LAB_SBC_TARGET)
    printf '%s' "${t:-sbc-real}"
}

# SBC real: confere o clone do Flux e o arquivo do token sem ler o conteudo do token
check_real_sbc() {
    [[ $(sbc_target) == sbc-real ]] || return 0
    local src tok
    src=$(env_get LAB_FLUX_SRC)
    tok=$(env_get LAB_SIGNALWIRE_TOKEN_FILE)
    [[ -f ${src}/database/flux-6.4.sql && -d ${src}/freeswitch/scripts/flux ]] \
        || die "LAB_FLUX_SRC nao e um clone do repositorio sbc: ${src} (ajuste no ${ENV_FILE})"
    local scripts
    scripts=$(env_get LAB_FLUX_SCRIPTS)
    [[ -f ${scripts}/flux/flux.lua ]] \
        || die "LAB_FLUX_SCRIPTS sem flux/flux.lua: ${scripts} (diretorio scripts do FreeSWITCH)"
    [[ -s ${tok} ]] || die "token da SignalWire ausente: ${tok} (LAB_SIGNALWIRE_TOKEN_FILE no ${ENV_FILE})"
    if [[ $(stat -f '%Lp' "${tok}" 2>/dev/null || stat -c '%a' "${tok}") != 600 ]]; then
        warn "${tok} deveria ter permissao 0600"
    fi
    if grep -qx 'COLE_O_TOKEN' "${tok}"; then
        die "${tok} ainda tem o texto de exemplo; grave o token da SignalWire nele"
    fi
}

cmd_up() {
    require_docker
    ensure_env
    check_real_sbc
    install -d -m 0700 "${OUT_DIR}" "${OUT_DIR}/results"
    # Os servidores geram chaves de host novas a cada subida: a confianca anterior nao vale
    rm -f "${OUT_DIR}/known_hosts"
    log "construindo e subindo (a primeira vez baixa pacotes e leva alguns minutos)"
    "${COMPOSE[@]}" up -d --build
    wait_cluster
    if [[ -f ${OUT_DIR}/loadtest.conf ]]; then
        migrate_conf
        write_secrets
    else
        cmd_conf
    fi
    if [[ $(sbc_target) == sbc-real ]]; then
        cmd_flux || warn "preparacao do banco do Flux falhou; repita com: $0 flux"
        wait_sbc
    fi
    cmd_zabbix || warn "configuracao do Zabbix falhou; repita com: $0 zabbix"
    cmd_status
    cat <<EOF

Proximos passos:
  $0 keys
  $0 shell
  cd /opt/flux-loadtest
  ./flux-loadtest.sh check -c /etc/flux-loadtest/loadtest.conf
EOF
}

# ------------------------------------------------------------------ banco do Flux (SBC real)
root_sql() {
    "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$(env_get LAB_MYSQL_ROOT_PASSWORD)" banco-master-sbc-stfc \
        mysql -uroot --default-character-set=utf8 "$@"
}

# Ramais do laboratorio: senhas estaveis entre subidas (out/sip_devices.csv, so local).
# out/sip_devices.sipp.csv: mesmo conteudo no formato -inf do SIPp (lab/sip/register.xml).
devices_file() {
    local n i f="${OUT_DIR}/sip_devices.csv"
    n=$(env_get LAB_SIP_DEVICES)
    n=${n:-20}
    if [[ ! ${n} =~ ^[0-9]+$ ]] || ((n < 1 || n > 900)); then
        die "LAB_SIP_DEVICES invalido (1-900)"
    fi
    if [[ ! -s ${f} ]] || (( $(grep -c '^[0-9]' "${f}") != n )); then
        (
            umask 077
            printf 'usuario;senha;did\n'
            for ((i = 0; i < n; i++)); do
                printf '%d;%s;5511300%05d\n' $((1000 + i)) "$(rand | cut -c1-16)" $((1000 + i))
            done
        ) > "${f}"
        log "${n} ramais gerados em ${f}" >&2
    fi
    (
        umask 077
        printf 'SEQUENTIAL\n'
        awk -F';' 'NR > 1 && $1 ~ /^[0-9]+$/ { printf "%s;[authentication username=%s password=%s]\n", $1, $1, $2 }' "${f}"
    ) > "${OUT_DIR}/sip_devices.sipp.csv"
    printf '%s' "${f}"
}

flux_seed_sql() {
    local devices=$1 ndids=$2 vip_pass
    vip_pass=$(env_get LAB_FLUX_DB_PASSWORD)
    cat <<SQL
-- gerado pelo lab.sh: usuario da aplicacao e dados do laboratorio (idempotente)
-- 172.30.% = servidores do laboratorio; 127.0.0.1/localhost = DEFINER dos triggers e views do schema
CREATE USER IF NOT EXISTS 'fluxuser'@'172.30.%' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
ALTER USER 'fluxuser'@'172.30.%' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
GRANT ALL PRIVILEGES ON flux.* TO 'fluxuser'@'172.30.%';
CREATE USER IF NOT EXISTS 'fluxuser'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
ALTER USER 'fluxuser'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
GRANT ALL PRIVILEGES ON flux.* TO 'fluxuser'@'127.0.0.1';
CREATE USER IF NOT EXISTS 'fluxuser'@'localhost' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
ALTER USER 'fluxuser'@'localhost' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
GRANT ALL PRIVILEGES ON flux.* TO 'fluxuser'@'localhost';
USE flux;
-- OpenSIPS na frente do pool: ACL "default" e "event" do FreeSWITCH (fs/lib/flux.xml.php)
-- o PHP (fs/lib/flux.lib.php) so le group_title IN ('global','opensips',...); no schema 6.4
-- estas chaves estao em 'signup' e a ACL nao incluiria o OpenSIPS.
-- IP publico do OpenSIPS: origem das chamadas de operadora (load_balancer) e do event socket
UPDATE \`system\` SET value = '0', group_title = 'opensips' WHERE name = 'opensips';
UPDATE \`system\` SET value = '172.30.177.163', group_title = 'opensips' WHERE name = 'opensips_domain';
-- conta de teste (id 2 do schema, pos-paga): sem limite de canais e com credito para nao
-- cair em NO_SUFFICIENT_FUND (o dialplan confere o saldo mesmo nas chamadas de entrada)
UPDATE accounts SET maxchannels = 0, status = 0, deleted = 0, expiry = '2046-07-25 11:26:24',
  credit_limit = 100000000 WHERE id = 2;
DELETE FROM sip_devices WHERE username BETWEEN '1000' AND '1999' AND accountid = 2;
SQL
    # perfil default como em producao: operadoras (load_balancer) na porta 5070 do IP
    # publico, com a midia no mesmo IP (pub_ip_v4 vem do vars.xml gerado pelo start.sh)
    cat <<'SQL'
UPDATE sip_profiles SET sip_port = '5070', sip_ip = '$${pub_ip_v4}', status = 0,
  profile_data = JSON_SET(profile_data, '$."rtp-ip"', '$${pub_ip_v4}', '$."ext-rtp-ip"', '$${pub_ip_v4}',
    '$."ext-sip-ip"', '$${pub_ip_v4}', '$."presence-hosts"', '$${domain},$${pub_ip_v4}')
  WHERE id = 1;
SQL
    # [lab] ramais dos devices do macOS (perfil lab-mac, dispatcher setid 2)
    awk -F';' 'NR > 1 && $1 ~ /^[0-9]+$/ {
        printf "INSERT INTO sip_devices (username, sip_profile_id, reseller_id, accountid, dir_params, dir_vars, status, creation_date, last_modified_date, call_waiting) VALUES (%c%s%c, 100, 0, 2, %c{\"password\":\"%s\",\"vm-enabled\":\"true\",\"vm-password\":\"%s\",\"vm-mailto\":\"\",\"vm-attach-file\":\"false\",\"vm-keep-local-after-email\":\"true\",\"vm-email-all-messages\":\"false\"}%c, %c{\"effective_caller_id_name\":\"Lab %s\",\"effective_caller_id_number\":\"%s\"}%c, 0, NOW(), NOW(), 0);\n",
            39, $1, 39, 39, $2, substr($1, 1, 4), 39, 39, $1, $1, 39 }' "${devices}"
    cat <<'SQL'
DELETE FROM dids WHERE accountid = 2 AND (number LIKE '55519%' OR number LIKE '5511300%');
SQL
    # DIRECT-IP (call_type 2): DIDs do teste de carga -> atendedor SIPp da vm-teste. O FS faz
    # bridge sofia/<perfil>/<DID>@<extensions> (custom_inbound_2 do flux.xml.lua)
    awk -v n="${ndids}" -v dst="${LAB_UAS_ADDR}" 'BEGIN {
        cols = "INSERT INTO dids (number, accountid, inc, extensions, status, call_type, leg_timeout, product_id, always, always_destination, user_busy, user_busy_destination, user_not_registered, user_not_registered_destination, no_answer, no_answer_destination, failover_extensions, last_modified_date) VALUES "
        for (i = 0; i < n; i++) {
            if (i % 1000 == 0) printf "%s%s", (i ? ";\n" : ""), cols; else printf ","
            printf "(%c55519%08d%c,2,60,%c%s%c,0,2,30,0,0,%c%c,0,%c%c,0,%c%c,0,%c%c,%c%c,NOW())", 39, i, 39, 39, dst, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39
        }
        if (n > 0) printf ";\n"
    }'
    # DID-LOCAL (call_type 0): um DID por ramal do macOS
    awk -F';' 'NR > 1 && $1 ~ /^[0-9]+$/ {
        printf "INSERT INTO dids (number, accountid, inc, extensions, status, call_type, leg_timeout, product_id, always, always_destination, user_busy, user_busy_destination, user_not_registered, user_not_registered_destination, no_answer, no_answer_destination, failover_extensions, last_modified_date) VALUES (%c%s%c,2,60,%c%s%c,0,0,30,0,0,%c%c,0,%c%c,0,%c%c,0,%c%c,%c%c,NOW());\n",
            39, $3, 39, 39, $1, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39 }' "${devices}"
    # por ultimo: o start.sh do SBC espera este perfil para subir o FreeSWITCH.
    # [lab] perfil dos devices do macOS: IP interno (dispatcher setid 2), midia anunciada
    # em 127.0.0.1 (portas de RTP publicadas pelo Docker Desktop)
    cat <<'SQL'
DELETE FROM sip_profiles WHERE id = 100 OR name = 'lab-mac';
INSERT INTO sip_profiles (id, name, sip_ip, sip_port, profile_data, created_date, last_modified_date, accountid, status)
  SELECT 100, 'lab-mac', '$${local_ip_v4}', '5080',
    JSON_SET(profile_data, '$."rtp-ip"', '$${local_ip_v4}', '$."ext-rtp-ip"', '127.0.0.1',
      '$."ext-sip-ip"', '$${local_ip_v4}', '$."presence-hosts"', '$${domain},$${local_ip_v4}'),
    NOW(), NOW(), 0, 0
  FROM sip_profiles WHERE id = 1;
SQL
}

cmd_flux() {
    require_docker
    [[ $(sbc_target) == sbc-real ]] || { log "LAB_SBC_TARGET=$(sbc_target): banco do Flux nao e necessario"; return 0; }
    local src f n devices ndids errlog="${OUT_DIR}/flux-schema.log"
    src=$(env_get LAB_FLUX_SRC)
    [[ -f ${src}/database/flux-6.4.sql ]] || die "schema do Flux nao encontrado em ${src}/database"
    install -d -m 0700 "${OUT_DIR}"
    n=$(root_sql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'flux' AND table_name = 'sip_profiles'") \
        || die "banco indisponivel (veja: $0 status)"
    if [[ ${n} == 0 ]]; then
        log "carregando o schema do Flux de ${src}/database (como o flux_install.sh; erros em ${errlog})"
        : > "${errlog}"
        root_sql -e "CREATE DATABASE IF NOT EXISTS flux"
        for f in database/flux-6.4.sql database/flux-tables.sql database/flux-6.4.1.sql database/flux-views.sql \
                 web_interface/flux/addons/plugins/ringgroup/database/ringgroup_1.0.0.sql \
                 web_interface/flux/addons/plugins/language_portuguese/database/language_portuguese_2.0.0.sql; do
            [[ -r ${src}/${f} ]] || { warn "ausente: ${f}"; continue; }
            printf '== %s\n' "${f}" >> "${errlog}"
            root_sql -f flux < "${src}/${f}" >> "${errlog}" 2>&1 || true
        done
        # migracoes na ordem do run_database_migrations (update-DD-MM-AAAA.sql por data)
        while IFS= read -r f; do
            printf '== %s\n' "${f#"${src}/"}" >> "${errlog}"
            root_sql -f flux < "${f}" >> "${errlog}" 2>&1 || true
        done < <(find "${src}/database/updates" -name 'update-*.sql' | sort -t '-' -k 4,4n -k 3,3n -k 2,2n)
        log "schema carregado: $(root_sql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'flux'") tabelas; $(grep -c '^ERROR' "${errlog}" || true) erros ignorados (-f, como no instalador)"
    else
        log "schema do Flux ja existe no cluster"
    fi
    devices=$(devices_file)
    ndids=$(env_get LAB_DIDS)
    [[ ${ndids:-100000} =~ ^[0-9]+$ ]] || die "LAB_DIDS invalido"
    log "gravando fluxuser, ramais ($(grep -c '^[0-9]' "${devices}")), ${ndids} DIDs DIRECT-IP para ${LAB_UAS_ADDR} e perfis SIP"
    flux_seed_sql "${devices}" "${ndids}" | root_sql || die "falha ao gravar os dados do laboratorio"
    log "banco do Flux pronto"
}

# Espera o FreeSWITCH e o OpenSIPS reais subirem (o start.sh espera o banco)
wait_sbc() {
    local i ok
    log "aguardando FreeSWITCH (sbc-stfc-1, sbc-stfc-02) e OpenSIPS"
    for ((i = 0; i < 150; i++)); do
        ok=0
        "${COMPOSE[@]}" exec -T sbc-stfc-1 test -f /run/flux-lab-started 2>/dev/null && ok=$((ok + 1))
        "${COMPOSE[@]}" exec -T sbc-stfc-02 test -f /run/flux-lab-started 2>/dev/null && ok=$((ok + 1))
        if ((ok == 2)); then
            "${COMPOSE[@]}" logs --no-log-prefix sbc-stfc-1 sbc-stfc-02 2>/dev/null | grep -E 'ativo|AVISO|ERRO' | tail -n 6 | sed 's/^/  /'
            return 0
        fi
        sleep 2
    done
    warn "SBC nao terminou de subir em 5 min; veja: docker compose -p flux-stfc-lab logs sbc-stfc-1"
}

cmd_devices() {
    local f="${OUT_DIR}/sip_devices.csv" port
    [[ -s ${f} ]] || die "ramais ainda nao gerados; rode '$0 up'"
    port=$(port LAB_PORT_SIP 5060)
    cat <<EOF
SIP devices do laboratorio (somente local; senhas em ${f#"${LAB_DIR}/"}):
  Servidor / registrar / outbound proxy: 127.0.0.1:${port} (UDP)
  Dominio: 127.0.0.1    Usuario de autenticacao = usuario    Codec: PCMA ou PCMU

  usuario  senha             DID (ligar do teste de carga ou de outro ramal)
EOF
    awk -F';' 'NR > 1 { printf "  %-8s %-17s %s\n", $1, $2, $3 }' "${f}"
    cat <<EOF

  Teste de carga: DIDs 55519xxxxxxxx DIRECT-IP para o atendedor da vm-teste (${LAB_UAS_ADDR}).
  Midia: RTP do FreeSWITCH em 127.0.0.1:$(port LAB_RTP1_START 16384)-$(port LAB_RTP2_END 16783)/udp.
EOF
}

cmd_zabbix() {
    require_docker
    [[ -f ${OUT_DIR}/loadtest.conf ]] || die "configuracao ausente; rode '$0 up'"
    migrate_conf
    write_secrets
    log "Zabbix: senha do Admin, token de API, templates e hosts"
    "${COMPOSE[@]}" exec -T vm-teste python3 /opt/flux-loadtest/lib/flux_zabbix.py bootstrap \
        --api-url http://172.30.177.11:8080/api_jsonrpc.php \
        --new-password-file /etc/flux-loadtest/zabbix_admin.pass \
        --token-file /etc/flux-loadtest/zabbix_api.token
    "${COMPOSE[@]}" exec -T vm-teste /opt/flux-loadtest/flux-loadtest.sh zabbix setup --import-template \
        -c /etc/flux-loadtest/loadtest.conf
}

cmd_urls() {
    cat <<EOF

Acesso pelo macOS (somente 127.0.0.1):
  Interface web (nginx + PHP-FPM)  https://127.0.0.1:$(port LAB_PORT_WEB_HTTPS 8443)/   http://127.0.0.1:$(port LAB_PORT_WEB_HTTP 8081)/
  Zabbix                           http://127.0.0.1:$(port LAB_PORT_ZABBIX_WEB 8080)/   usuario Admin, senha em ${OUT_DIR#"${LAB_DIR}/"}/zabbix_admin.pass
  Zabbix trapper                   127.0.0.1:$(port LAB_PORT_ZABBIX_TRAPPER 10051)
  SIP devices (UDP)                127.0.0.1:$(port LAB_PORT_SIP 5060)   ramais e senhas: $0 devices
  RTP do FreeSWITCH (UDP)          127.0.0.1:$(port LAB_RTP1_START 16384)-$(port LAB_RTP1_END 16583) (sbc-stfc-1), $(port LAB_RTP2_START 16584)-$(port LAB_RTP2_END 16783) (sbc-stfc-02)
  SSH (usuarios loadtest/admin)    sbc-stfc-1 :$(port LAB_PORT_SSH_SBC1 22163)  sbc-stfc-02 :$(port LAB_PORT_SSH_SBC2 22162)  banco-master :$(port LAB_PORT_SSH_DB1 22161)  banco-slave :$(port LAB_PORT_SSH_DB2 22164)  interfaceweb :$(port LAB_PORT_SSH_WEB 22165)
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
    printf '\nZabbix: '
    "${COMPOSE[@]}" exec -T vm-teste /opt/flux-loadtest/flux-loadtest.sh zabbix check \
        -c /etc/flux-loadtest/loadtest.conf 2>&1 | sed 's/^\[[0-9:]*\] zabbix: //' | paste -sd ';' - \
        || warn "zabbix check falhou"
    cmd_urls
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
        flux)            cmd_flux ;;
        devices)         cmd_devices ;;
        zabbix)          cmd_zabbix ;;
        shell)           require_docker; exec "${COMPOSE[@]}" exec vm-teste bash ;;
        interna|externa) cmd_net "${action}" ;;
        down)
            require_docker
            if [[ ${1:-} == --zabbix ]]; then
                "${COMPOSE[@]}" down --remove-orphans --volumes
            elif [[ -z ${1:-} ]]; then
                "${COMPOSE[@]}" down --remove-orphans
            else
                die "opcao invalida para down: $1"
            fi
            ;;
        ""|-h|--help)    usage ;;
        *)               usage >&2; die "acao invalida: ${action}" ;;
    esac
}

main "$@"
