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
#
# Dois modos (LAB_INIT):
#   direct  (padrao) container Docker: processos iniciados direto, IPs do docker-compose.yml
#   systemd lab em VMs Debian 12 (lab/vm/roles/sbc.sh): unidades systemd e IPs do inventario
#           (LAB_DB_VIP, LAB_GEN_IP, LAB_FS_PUB_IPS, LAB_FS_INT_IPS, LAB_DEV_PROFILE...)

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
LAB_INIT=${LAB_INIT:-direct}
# Enderecos do laboratorio (padrao: redes do docker-compose.yml)
LAB_GEN_IP=${LAB_GEN_IP:-172.30.177.50}
LAB_FS_PUB_IPS=${LAB_FS_PUB_IPS:-172.30.177.163 172.30.177.162}
LAB_FS_INT_IPS=${LAB_FS_INT_IPS:-172.30.4.163 172.30.4.162}
LAB_DEV_PROFILE=${LAB_DEV_PROFILE:-lab-mac}
# Sockets 5062 anunciando 127.0.0.1: so para os devices do macOS via Docker Desktop
LAB_MAC_SOCKETS=${LAB_MAC_SOCKETS:-1}

readonly FLUX_SRC=${LAB_FLUX_SRC_DIR:-/opt/flux-src}
readonly FLUX_SCRIPTS=${LAB_FLUX_SCRIPTS_DIR:-/opt/flux-scripts}
readonly TPL_DIR=${LAB_TEMPLATE_DIR:-/opt/flux-lab/sbc-real}
readonly VIP=${LAB_DB_VIP:-172.30.4.100}
readonly FS_CONF=/etc/freeswitch

for v in LAB_RTP_START LAB_RTP_END LAB_MAC_SIP_PORT LAB_OPENSIPS_LOG_LEVEL; do
    [[ ${!v} =~ ^[0-9]+$ ]] || die "${v} invalido: ${!v}"
done
[[ ${LAB_FLUX_DB_PASSWORD} =~ ^[A-Za-z0-9]+$ ]] || die "LAB_FLUX_DB_PASSWORD deve ser alfanumerica (vai em URL e XML)"
[[ ${LAB_FS_CLI_PASSWORD} =~ ^[A-Za-z0-9]+$ ]] || die "LAB_FS_CLI_PASSWORD deve ser alfanumerica"
[[ ${LAB_INIT} == direct || ${LAB_INIT} == systemd ]] || die "LAB_INIT invalido: ${LAB_INIT} (direct ou systemd)"
[[ ${LAB_MAC_SOCKETS} == [01] ]] || die "LAB_MAC_SOCKETS deve ser 0 ou 1"
[[ ${LAB_DEV_PROFILE} =~ ^[A-Za-z0-9_-]+$ ]] || die "LAB_DEV_PROFILE invalido: ${LAB_DEV_PROFILE}"
for ip in ${VIP} ${LAB_GEN_IP} ${LAB_FS_PUB_IPS} ${LAB_FS_INT_IPS}; do
    [[ ${ip} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "IP invalido: ${ip}"
done
for d in freeswitch/scripts/flux freeswitch/fs freeswitch/conf/autoload_configs config; do
    [[ -d ${FLUX_SRC}/${d} ]] || die "${FLUX_SRC}/${d} ausente: confira LAB_FLUX_SRC no .env (clone do repositorio sbc)"
done

db() { MYSQL_PWD=${LAB_FLUX_DB_PASSWORD} mysql -h "${VIP}" -u fluxuser -N -B --connect-timeout=5 flux "$@"; }

# svc UNIDADE COMANDO...: no modo systemd habilita e reinicia a unidade; no Docker executa o comando
svc() {
    local unit=$1
    shift
    if [[ ${LAB_INIT} == systemd ]]; then
        systemctl enable "${unit}" >/dev/null 2>&1 || true
        systemctl restart "${unit}" || die "falha ao iniciar ${unit} (journalctl -u ${unit})"
    else
        "$@"
    fi
}

# Espera o lab.sh carregar o schema do Flux e os dados do laboratorio (ate 30 min)
wait_flux_db() {
    local i
    log "aguardando o schema do Flux no banco (${VIP}, usuario fluxuser)"
    for ((i = 0; i < 900; i++)); do
        if [[ $(db -e "SELECT COUNT(*) FROM sip_profiles WHERE name = '${LAB_DEV_PROFILE}'" 2>/dev/null) == 1 ]]; then
            log "schema do Flux disponivel"
            return 0
        fi
        sleep 2
    done
    die "schema do Flux nao apareceu em 30 min (rode: lab.sh flux ou vmlab.sh flux)"
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
    svc php7.3-fpm php-fpm7.3 -D
    svc nginx nginx
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
    # O container tem duas interfaces: local_ip_v4 fixo no IP interno (perfil lab-mac) e
    # pub_ip_v4 no "publico", usado pelo perfil default (lab.sh), como em producao, onde
    # o perfil das operadoras escuta e anuncia midia no IP publico (200.159.177.x:5070)
    sed -i "0,/<include>/s#<include>#<include>\n  <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v4=${LAB_INT_IP}\"/>\n  <X-PRE-PROCESS cmd=\"set\" data=\"pub_ip_v4=${LAB_PUB_IP}\"/>#" "${FS_CONF}/vars.xml"

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
    if [[ ${LAB_INIT} == systemd ]]; then
        # Os pacotes da SignalWire nao trazem unidade systemd. Mesma linha de comando do
        # container, como root: o Lua/ODBC do Flux le arquivos root:www-data
        cat > /etc/systemd/system/freeswitch.service <<EOF
[Unit]
Description=FreeSWITCH (laboratorio Flux, gerado pelo start.sh)
Wants=network-online.target
After=network-online.target local-fs.target

[Service]
Type=forking
RuntimeDirectory=freeswitch
PIDFile=/run/freeswitch/freeswitch.pid
ExecStart=/usr/bin/freeswitch -ncwait -nonat -conf ${FS_CONF} -log /var/log/freeswitch -db /var/lib/freeswitch/db -run /run/freeswitch
ExecStop=/usr/bin/freeswitch -stop -run /run/freeswitch
TimeoutStartSec=120
Restart=on-failure
RestartSec=5
LimitNOFILE=999999
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        svc freeswitch
    else
        freeswitch -nc -nonat -conf "${FS_CONF}" -log /var/log/freeswitch -db /var/lib/freeswitch/db >/dev/null 2>&1
    fi
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
    # Origens: grupo 10 = operadoras (VM de teste), grupo 20 = pool FreeSWITCH (as duas faces)
    # load_balancer grupo 1 (chamadas de operadora) -> perfil default (5070, IP publico);
    #   o event socket tambem pelo publico: a ACL "event" do Flux libera opensips_domain
    # dispatcher setid 2 (REGISTER e chamadas dos devices) -> perfil dos devices (5080, interno)
    local ip rows="" lb="" ds=""
    rows="  (10, '${LAB_GEN_IP}', 32, 0, 'any', 'flux-lab')"
    for ip in $(printf '%s\n' ${LAB_FS_PUB_IPS} ${LAB_FS_INT_IPS} | awk '!seen[$0]++'); do
        rows+=$',\n'"  (20, '${ip}', 32, 0, 'any', 'flux-lab')"
    done
    for ip in ${LAB_FS_PUB_IPS}; do
        lb+="${lb:+$',\n'}  (1, 'sip:${ip}:5070', 'channels=fs://:${LAB_FS_CLI_PASSWORD}@${ip}:8021', 1, 'flux-lab')"
    done
    for ip in ${LAB_FS_INT_IPS}; do
        ds+="${ds:+$',\n'}  (2, 'sip:${ip}:5080', 0, '1', 0, 'flux-lab')"
    done
    db <<SQL
DELETE FROM address WHERE context_info = 'flux-lab';
INSERT INTO address (grp, ip, mask, port, proto, context_info) VALUES
${rows};
DELETE FROM load_balancer WHERE description = 'flux-lab';
INSERT INTO load_balancer (group_id, dst_uri, resources, probe_mode, description) VALUES
${lb};
DELETE FROM dispatcher WHERE description = 'flux-lab';
INSERT INTO dispatcher (setid, destination, state, weight, priority, description) VALUES
${ds};
SQL
}

setup_opensips() {
    opensips_tables
    install -d -m 0755 /etc/opensips /run/opensips
    # mpath pela arquitetura da maquina; sem os sockets do macOS fora do Docker; um socket
    # por IP:porta quando a VM tem uma interface so (IP publico = interno)
    sed -e "s#@PUB_IP@#${LAB_PUB_IP}#g" -e "s#@INT_IP@#${LAB_INT_IP}#g" \
        -e "s#@MAC_SIP_PORT@#${LAB_MAC_SIP_PORT}#g" -e "s#@LOG_LEVEL@#${LAB_OPENSIPS_LOG_LEVEL}#g" \
        -e "s#@DB_URL@#mysql://fluxuser:${LAB_FLUX_DB_PASSWORD}@${VIP}:3306/flux#g" \
        -e "s#/usr/lib/x86_64-linux-gnu/opensips/#/usr/lib/$(uname -m)-linux-gnu/opensips/#" \
        "${TPL_DIR}/opensips.cfg.in" \
        | awk -v mac="${LAB_MAC_SOCKETS}" '/^socket=.*:5062 as / && mac == 0 { next }
                                           /^socket=/ && seen[$0]++ { next } { print }' \
        > /etc/opensips/opensips.cfg
    chmod 0640 /etc/opensips/opensips.cfg
    if [[ ${LAB_INIT} == systemd ]]; then
        chgrp opensips /etc/opensips/opensips.cfg
    fi
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
    if [[ ${LAB_INIT} == systemd ]]; then
        # unidade do pacote em primeiro plano (-F): o log em stderr vai para o journal
        printf 'S_MEMORY=256\nP_MEMORY=32\n' > /etc/default/opensips
        install -d -m 0755 /etc/systemd/system/opensips.service.d
        cat > /etc/systemd/system/opensips.service.d/flux-lab.conf <<'EOF'
[Service]
Type=simple
PIDFile=
ExecStart=
ExecStart=/usr/sbin/opensips -F -f /etc/opensips/opensips.cfg -m $S_MEMORY -M $P_MEMORY
ExecStop=
EOF
        systemctl daemon-reload
        svc opensips
    else
        opensips -F -f /etc/opensips/opensips.cfg -m 256 -M 32 >>/var/log/opensips.log 2>&1 &
    fi
    local i
    for ((i = 0; i < 30; i++)); do
        if opensips-cli -x mi version >/dev/null 2>&1; then
            log "OpenSIPS $(opensips -V | awk 'NR == 1 { print $3 }') ativo em ${LAB_PUB_IP}:5060$([[ ${LAB_INT_IP} != "${LAB_PUB_IP}" ]] && printf ' e %s:5060' "${LAB_INT_IP}")$( ((LAB_MAC_SOCKETS)) && printf ' e :5062 (devices do macOS)')"
            return 0
        fi
        sleep 1
    done
    log "AVISO: OpenSIPS sem resposta no MI; veja /var/log/opensips.log (Docker) ou journalctl -u opensips"
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
