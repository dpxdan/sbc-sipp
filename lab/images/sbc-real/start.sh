#!/usr/bin/env bash
#
# Servidores SBC reais do laboratorio STFC (stack FluxSBC):
#   fs       -> FreeSWITCH 1.11.3 com a configuracao do Flux (flux_install.sh):
#               xml_curl (diretorio e sofia.conf) no PHP-FPM 7.3 + nginx em 127.0.0.1:8735,
#               dialplan em Lua com ODBC (DSN FLUX) e CDR por json_cdr
#   opensips -> OpenSIPS 3.6 com o opensips.cfg de producao (mid_registrar + load_balancer)
# Schema, PHP do xml_curl e configs vem do clone do repositorio sbc em /opt/flux-src; os scripts
# Lua do dialplan vem de /opt/flux-scripts (LAB_FLUX_SCRIPTS, padrao: snapshot do sbc01 de
# producao), com fallback para os do clone. Ambos somente leitura.
# O banco (schema Flux, usuario fluxuser e dados do laboratorio) e preparado pelo lab.sh no
# Percona XtraDB Cluster; este script espera o schema antes de subir o FreeSWITCH.

set -Eeuo pipefail

log() { printf '[%(%H:%M:%S)T] %s: %s\n' -1 "$(hostname)" "$*"; }
die() { log "ERRO: $*"; exit 1; }

: "${LAB_PUB_IP:?LAB_PUB_IP nao definido}"
: "${LAB_INT_IP:?LAB_INT_IP nao definido}"
: "${LAB_FLUX_DB_PASSWORD:?defina no .env (lab.sh up gera)}"
: "${LAB_FS_CLI_PASSWORD:?defina no .env (lab.sh up gera)}"
LAB_SIP_ROLES=${LAB_SIP_ROLES:-fs}
LAB_RTP_START=${LAB_RTP_START:-16384}
LAB_RTP_END=${LAB_RTP_END:-16583}
LAB_MAC_SIP_PORT=${LAB_MAC_SIP_PORT:-5060}
LAB_OPENSIPS_LOG_LEVEL=${LAB_OPENSIPS_LOG_LEVEL:-3}

readonly FLUX_SRC=/opt/flux-src
readonly FLUX_SCRIPTS=/opt/flux-scripts
readonly VIP=172.30.4.100
readonly FS_CONF=/etc/freeswitch

for v in LAB_RTP_START LAB_RTP_END LAB_MAC_SIP_PORT LAB_OPENSIPS_LOG_LEVEL; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "${v} invalido: ${!v}"
done
[[ ${LAB_FLUX_DB_PASSWORD} =~ ^[A-Za-z0-9]+$ ]] || die "LAB_FLUX_DB_PASSWORD deve ser alfanumerica (vai em URL e XML)"
[[ ${LAB_FS_CLI_PASSWORD} =~ ^[A-Za-z0-9]+$ ]] || die "LAB_FS_CLI_PASSWORD deve ser alfanumerica"
for d in freeswitch/scripts/flux freeswitch/fs freeswitch/conf/autoload_configs config; do
    [[ -d ${FLUX_SRC}/${d} ]] || die "${FLUX_SRC}/${d} ausente: confira LAB_FLUX_SRC no .env (clone do repositorio sbc)"
done

db() { MYSQL_PWD=${LAB_FLUX_DB_PASSWORD} mysql -h "${VIP}" -u fluxuser -N -B --connect-timeout=5 flux "$@"; }

# Espera o lab.sh carregar o schema do Flux e os dados do laboratorio (ate 30 min)
wait_flux_db() {
    local i
    log "aguardando o schema do Flux no banco (${VIP}, usuario fluxuser)"
    for ((i = 0; i < 900; i++)); do
        if [[ $(db -e "SELECT COUNT(*) FROM sip_profiles WHERE name = 'lab-mac'" 2>/dev/null) == 1 ]]; then
            log "schema do Flux disponivel"
            return 0
        fi
        sleep 2
    done
    die "schema do Flux nao apareceu em 30 min (rode: lab.sh flux)"
}

# ------------------------------------------------------------------ comum (PHP xml_curl + ODBC)
setup_flux_common() {
    install -d -m 0755 /var/lib/flux /var/log/flux /var/www/html
    # Configuracao do PHP (fs/lib/flux.db.php) e do Lua (flux.lua), como no flux_install.sh
    sed -e "s#^dbhost = .*#dbhost = ${VIP}#" -e "s#^dbpass = .*#dbpass = ${LAB_FLUX_DB_PASSWORD}#" \
        "${FLUX_SRC}/config/flux-config.conf" > /var/lib/flux/flux-config.conf
    sed -e "s#^DB_PASSWD=.*#DB_PASSWD = \"${LAB_FLUX_DB_PASSWORD}\"#" \
        "${FLUX_SRC}/config/flux.lua" > /var/lib/flux/flux.lua
    chown root:www-data /var/lib/flux/flux-config.conf /var/lib/flux/flux.lua
    chmod 0640 /var/lib/flux/flux-config.conf /var/lib/flux/flux.lua

    # DSN FLUX: driver MariaDB ODBC no lugar do libmyodbc8 do instalador (mesmo protocolo)
    install -m 0640 /dev/null /etc/odbc.ini
    cat > /etc/odbc.ini <<EOF
[FLUX]
Driver   = MariaDB Unicode
SERVER   = ${VIP}
PORT     = 3306
DATABASE = flux
USER     = fluxuser
PASSWORD = ${LAB_FLUX_DB_PASSWORD}
OPTION   = 67108864
CHARSET  = utf8
EOF

    ln -sfn "${FLUX_SRC}/freeswitch/fs" /var/www/html/fs
    local scripts="${FLUX_SRC}/freeswitch/scripts"
    if [[ -f ${FLUX_SCRIPTS}/flux/flux.lua ]]; then
        scripts=${FLUX_SCRIPTS}
    fi
    rm -rf /usr/share/freeswitch/scripts
    ln -sfn "${scripts}" /usr/share/freeswitch/scripts
    log "scripts Lua do dialplan: $([[ ${scripts} == "${FLUX_SCRIPTS}" ]] && echo 'LAB_FLUX_SCRIPTS' || echo 'clone do repositorio sbc') (${scripts})"
    cp -f "${FLUX_SRC}/web_interface/nginx/deb_fs.conf" /etc/nginx/conf.d/fs.conf
    # sem IPv6 no container
    sed -i '/listen \[::1\]:8735/d' /etc/nginx/conf.d/fs.conf
    mkdir -p /run/php
    php-fpm7.3 -D
    nginx
    log "PHP-FPM 7.3 e nginx (127.0.0.1:8735) ativos"
}

# ------------------------------------------------------------------ FreeSWITCH
setup_fs() {
    cp -a "${FLUX_SRC}/freeswitch/conf/autoload_configs/." "${FS_CONF}/autoload_configs/"
    cp -f "${FLUX_SRC}/freeswitch/conf/vars.xml" "${FS_CONF}/vars.xml"
    mkdir -p "${FS_CONF}/templates"
    cp -a "${FLUX_SRC}/freeswitch/conf/templates/." "${FS_CONF}/templates/"
    cp -f "${FLUX_SRC}"/freeswitch/sounds/*.wav /usr/share/freeswitch/sounds/ 2>/dev/null || true

    sed -i "s#dbname:user:password#FLUX:fluxuser:${LAB_FLUX_DB_PASSWORD}#g" "${FS_CONF}/vars.xml"
    # local_ip_v4 fixo no IP interno: o container tem duas interfaces
    sed -i "0,/<include>/s#<include>#<include>\n  <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v4=${LAB_INT_IP}\"/>#" "${FS_CONF}/vars.xml"

    # normalize_freeswitch do flux_install.sh + faixa de RTP publicada no macOS
    local sw="${FS_CONF}/autoload_configs/switch.conf.xml"
    sed -i -e 's#max-sessions" value="1000#max-sessions" value="2000#' \
           -e 's#sessions-per-second" value="30#sessions-per-second" value="50#' \
           -e 's#max-db-handles" value="50#max-db-handles" value="500#' \
           -e 's#db-handle-timeout" value="10#db-handle-timeout" value="30#' \
           -e '/rtp-start-port\|rtp-end-port/d' "${sw}"
    sed -i "s#<settings>#<settings>\n    <param name=\"rtp-start-port\" value=\"${LAB_RTP_START}\"/>\n    <param name=\"rtp-end-port\" value=\"${LAB_RTP_END}\"/>#" "${sw}"

    # Modulos sem pacote no repositorio SignalWire para bookworm (codecs, sem efeito no teste)
    sed -i -e '/mod_bcg729/d' -e '/mod_g729/d' -e '/mod_h26x/d' "${FS_CONF}/autoload_configs/modules.conf.xml"

    # Event socket: senha do .env, todas as interfaces (OpenSIPS e coletor); ACL "event" do Flux
    cat > "${FS_CONF}/autoload_configs/event_socket.conf.xml" <<EOF
<configuration name="event_socket.conf" description="Socket Client">
  <settings>
    <param name="nat-map" value="false"/>
    <param name="listen-ip" value="0.0.0.0"/>
    <param name="listen-port" value="8021"/>
    <param name="password" value="${LAB_FS_CLI_PASSWORD}"/>
    <param name="apply-inbound-acl" value="event"/>
  </settings>
</configuration>
EOF

    rm -rf "${FS_CONF}/dialplan" "${FS_CONF}/directory" "${FS_CONF}/sip_profiles"
    mkdir -p "${FS_CONF}/dialplan" "${FS_CONF}/directory" "${FS_CONF}/sip_profiles"
    touch "${FS_CONF}/dialplan/flux.xml" "${FS_CONF}/directory/flux.xml" "${FS_CONF}/sip_profiles/flux.xml"

    mkdir -p /var/log/freeswitch/json_cdr /var/lib/freeswitch/storage /var/lib/freeswitch/recordings
    freeswitch -nc -nonat -conf "${FS_CONF}" -log /var/log/freeswitch -db /var/lib/freeswitch/db >/dev/null 2>&1
    local i
    for ((i = 0; i < 60; i++)); do
        if fs_cli -p "${LAB_FS_CLI_PASSWORD}" -x status 2>/dev/null | grep -q 'is ready'; then
            log "FreeSWITCH $(freeswitch -version | awk '{print $3}') ativo; perfis: $(fs_cli -p "${LAB_FS_CLI_PASSWORD}" -x 'sofia status' | awk '$2 == "profile" { printf "%s %s ", $1, $3 }')"
            return 0
        fi
        sleep 2
    done
    log "AVISO: FreeSWITCH sem resposta no event socket; veja /var/log/freeswitch/freeswitch.log"
}

# ------------------------------------------------------------------ OpenSIPS
# Tabelas do OpenSIPS no banco flux (schema oficial do pacote) e dados do laboratorio
opensips_tables() {
    local f tbl
    local -A files=([version]=standard [address]=permissions [load_balancer]=load_balancer
                    [dispatcher]=dispatcher [sip_trace]=tracer)
    for tbl in version address load_balancer dispatcher sip_trace; do
        f=/usr/share/opensips/mysql/${files[${tbl}]}-create.sql
        if [[ $(db -e "SHOW TABLES LIKE '${tbl}'") != "${tbl}" ]]; then
            [[ -r ${f} ]] || die "schema do OpenSIPS ausente: ${f}"
            db < "${f}"
            log "tabela ${tbl} criada (${f##*/})"
        fi
    done
    # Origens: grupo 10 = operadoras (vm-teste), grupo 20 = pool FreeSWITCH
    # load_balancer grupo 1 (chamadas de operadora) -> perfil default (5070)
    # dispatcher setid 2 (REGISTER e chamadas dos devices) -> perfil lab-mac (5080)
    db <<SQL
DELETE FROM address WHERE context_info = 'flux-lab';
INSERT INTO address (grp, ip, mask, port, proto, context_info) VALUES
  (10, '172.30.177.50', 32, 0, 'any', 'flux-lab'),
  (20, '172.30.4.163', 32, 0, 'any', 'flux-lab'),
  (20, '172.30.4.162', 32, 0, 'any', 'flux-lab');
DELETE FROM load_balancer WHERE description = 'flux-lab';
INSERT INTO load_balancer (group_id, dst_uri, resources, probe_mode, description) VALUES
  (1, 'sip:172.30.4.163:5070', 'channels=fs://:${LAB_FS_CLI_PASSWORD}@172.30.4.163:8021', 1, 'flux-lab'),
  (1, 'sip:172.30.4.162:5070', 'channels=fs://:${LAB_FS_CLI_PASSWORD}@172.30.4.162:8021', 1, 'flux-lab');
DELETE FROM dispatcher WHERE description = 'flux-lab';
INSERT INTO dispatcher (setid, destination, state, weight, priority, description) VALUES
  (2, 'sip:172.30.4.163:5080', 0, '1', 0, 'flux-lab'),
  (2, 'sip:172.30.4.162:5080', 0, '1', 0, 'flux-lab');
SQL
}

setup_opensips() {
    opensips_tables
    install -d -m 0755 /etc/opensips /run/opensips
    sed -e "s#@PUB_IP@#${LAB_PUB_IP}#g" -e "s#@INT_IP@#${LAB_INT_IP}#g" \
        -e "s#@MAC_SIP_PORT@#${LAB_MAC_SIP_PORT}#g" -e "s#@LOG_LEVEL@#${LAB_OPENSIPS_LOG_LEVEL}#g" \
        -e "s#@DB_URL@#mysql://fluxuser:${LAB_FLUX_DB_PASSWORD}@${VIP}:3306/flux#g" \
        /opt/flux-lab/sbc-real/opensips.cfg.in > /etc/opensips/opensips.cfg
    chmod 0640 /etc/opensips/opensips.cfg
    cat > /etc/opensips/opensips-cli.cfg <<'EOF'
[default]
log_level: WARNING
prompt_name: opensips-cli
prompt_intro: OpenSIPS (laboratorio STFC)
prompt_emptyline_repeat_cmd: False
history_file: ~/.opensips-cli.history
history_file_size: 1000
output_type: pretty-print
communication_type: fifo
fifo_file: /run/opensips/opensips_fifo
EOF
    opensips -C -f /etc/opensips/opensips.cfg >/var/log/opensips-check.log 2>&1 \
        || die "opensips.cfg invalido; veja /var/log/opensips-check.log"
    opensips -F -f /etc/opensips/opensips.cfg -m 256 -M 32 >>/var/log/opensips.log 2>&1 &
    local i
    for ((i = 0; i < 30; i++)); do
        if opensips-cli -x mi version >/dev/null 2>&1; then
            log "OpenSIPS $(opensips -V | awk 'NR == 1 { print $3 }') ativo em ${LAB_PUB_IP}:5060, ${LAB_INT_IP}:5060 e :5062 (devices do macOS)"
            return 0
        fi
        sleep 1
    done
    log "AVISO: OpenSIPS sem resposta no MI; veja /var/log/opensips.log"
}

wait_flux_db
setup_flux_common
for role in ${LAB_SIP_ROLES}; do
    case "${role}" in
        fs)       setup_fs ;;
        opensips) ;;
        *)        log "papel SIP desconhecido: ${role}" ;;
    esac
done
# OpenSIPS depois do FS local: o load_balancer conecta no event socket ao subir
if [[ " ${LAB_SIP_ROLES} " == *" opensips "* ]]; then
    setup_opensips
fi
date +%s > /run/flux-lab-started
