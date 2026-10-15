# shellcheck shell=bash
#
# lab/lib/flux-db.sh - banco do Flux do laboratorio STFC (WEB-1437), comum ao lab em
# Docker (lab/lab.sh) e ao lab em VMs Debian 12 (lab/vm/vmlab.sh).
#
# Biblioteca para "source": nao altera opcoes do shell. O chamador define log, warn e die
# e as variaveis abaixo antes de usar as funcoes:
#   FLUXDB_OUT_DIR          diretorio local (0700) dos ramais gerados
#   FLUXDB_NET_PATTERN      host pattern do MySQL para os servidores (ex.: 172.30.%)
#   FLUXDB_OPENSIPS_DOMAIN  IP publico do OpenSIPS (ACL default/event do FreeSWITCH)
#   FLUXDB_UAS_ADDR         IP:porta do atendedor (destino dos DIDs DIRECT-IP)
#   FLUXDB_DEV_PROFILE      nome do perfil SIP dos devices (id 100, porta 5080)
#   FLUXDB_DEV_EXT_RTP_IP   ext-rtp-ip do perfil dos devices (127.0.0.1 no Docker Desktop;
#                           $${local_ip_v4} nas VMs)
# A execucao do SQL e do chamador: as funcoes so geram texto ou recebem a funcao de envio.

rand() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# Ramais do laboratorio: senhas estaveis entre subidas (sip_devices.csv, so local).
# sip_devices.sipp.csv: mesmo conteudo no formato -inf do SIPp (lab/sip/register.xml).
# fluxdb_devices_file N -> imprime o caminho do sip_devices.csv
fluxdb_devices_file() {
    local n=${1:-20} i f="${FLUXDB_OUT_DIR}/sip_devices.csv"
    if [[ ! ${n} =~ ^[0-9]+$ ]] || ((n < 1 || n > 900)); then
        die "quantidade de ramais invalida (1-900): ${n}"
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
    ) > "${FLUXDB_OUT_DIR}/sip_devices.sipp.csv"
    printf '%s' "${f}"
}

# Arquivos do schema na ordem do flux_install.sh (relativos ao clone do repositorio sbc)
fluxdb_schema_files() {
    printf '%s\n' database/flux-6.4.sql database/flux-tables.sql database/flux-6.4.1.sql \
        database/flux-views.sql \
        web_interface/flux/addons/plugins/ringgroup/database/ringgroup_1.0.0.sql \
        web_interface/flux/addons/plugins/language_portuguese/database/language_portuguese_2.0.0.sql
}

# fluxdb_load_schema SRC ERRLOG SQLFN
# Carrega o schema e as migracoes com "-f" (erros ignorados, como no instalador) usando a
# funcao SQLFN do chamador (ex.: root_sql), que repassa os argumentos ao cliente mysql.
fluxdb_load_schema() {
    local src=$1 errlog=$2 sqlfn=$3 f
    [[ -f ${src}/database/flux-6.4.sql ]] || die "schema do Flux nao encontrado em ${src}/database"
    : > "${errlog}"
    "${sqlfn}" -e "CREATE DATABASE IF NOT EXISTS flux"
    while IFS= read -r f; do
        [[ -r ${src}/${f} ]] || { warn "ausente: ${f}"; continue; }
        printf '== %s\n' "${f}" >> "${errlog}"
        "${sqlfn}" -f flux < "${src}/${f}" >> "${errlog}" 2>&1 || true
    done < <(fluxdb_schema_files)
    # migracoes na ordem do run_database_migrations (update-DD-MM-AAAA.sql por data)
    while IFS= read -r f; do
        printf '== %s\n' "${f#"${src}/"}" >> "${errlog}"
        "${sqlfn}" -f flux < "${f}" >> "${errlog}" 2>&1 || true
    done < <(find "${src}/database/updates" -name 'update-*.sql' | sort -t '-' -k 4,4n -k 3,3n -k 2,2n)
}

# fluxdb_seed_sql DEVICES NDIDS SENHA_FLUXUSER -> SQL idempotente dos dados do laboratorio
fluxdb_seed_sql() {
    local devices=$1 ndids=$2 vip_pass=$3
    local net=${FLUXDB_NET_PATTERN:?} osip=${FLUXDB_OPENSIPS_DOMAIN:?} uas=${FLUXDB_UAS_ADDR:?}
    local dev_profile=${FLUXDB_DEV_PROFILE:-lab-mac} dev_rtp=${FLUXDB_DEV_EXT_RTP_IP:-127.0.0.1}
    cat <<SQL
-- gerado pelo lab.sh: usuario da aplicacao e dados do laboratorio (idempotente)
-- ${net} = servidores do laboratorio; 127.0.0.1/localhost = DEFINER dos triggers e views do schema
CREATE USER IF NOT EXISTS 'fluxuser'@'${net}' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
ALTER USER 'fluxuser'@'${net}' IDENTIFIED WITH mysql_native_password BY '${vip_pass}';
GRANT ALL PRIVILEGES ON flux.* TO 'fluxuser'@'${net}';
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
UPDATE \`system\` SET value = '${osip}', group_title = 'opensips' WHERE name = 'opensips_domain';
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
    # [lab] ramais dos devices (perfil id 100, dispatcher setid 2)
    awk -F';' 'NR > 1 && $1 ~ /^[0-9]+$/ {
        printf "INSERT INTO sip_devices (username, sip_profile_id, reseller_id, accountid, dir_params, dir_vars, status, creation_date, last_modified_date, call_waiting) VALUES (%c%s%c, 100, 0, 2, %c{\"password\":\"%s\",\"vm-enabled\":\"true\",\"vm-password\":\"%s\",\"vm-mailto\":\"\",\"vm-attach-file\":\"false\",\"vm-keep-local-after-email\":\"true\",\"vm-email-all-messages\":\"false\"}%c, %c{\"effective_caller_id_name\":\"Lab %s\",\"effective_caller_id_number\":\"%s\"}%c, 0, NOW(), NOW(), 0);\n",
            39, $1, 39, 39, $2, substr($1, 1, 4), 39, 39, $1, $1, 39 }' "${devices}"
    cat <<'SQL'
DELETE FROM dids WHERE accountid = 2 AND (number LIKE '55519%' OR number LIKE '5511300%');
SQL
    # DIRECT-IP (call_type 2): DIDs do teste de carga -> atendedor SIPp da VM de teste. O FS
    # faz bridge sofia/<perfil>/<DID>@<extensions> (custom_inbound_2 do flux.xml.lua)
    awk -v n="${ndids}" -v dst="${uas}" 'BEGIN {
        cols = "INSERT INTO dids (number, accountid, inc, extensions, status, call_type, leg_timeout, product_id, always, always_destination, user_busy, user_busy_destination, user_not_registered, user_not_registered_destination, no_answer, no_answer_destination, failover_extensions, last_modified_date) VALUES "
        for (i = 0; i < n; i++) {
            if (i % 1000 == 0) printf "%s%s", (i ? ";\n" : ""), cols; else printf ","
            printf "(%c55519%08d%c,2,60,%c%s%c,0,2,30,0,0,%c%c,0,%c%c,0,%c%c,0,%c%c,%c%c,NOW())", 39, i, 39, 39, dst, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39
        }
        if (n > 0) printf ";\n"
    }'
    # DID-LOCAL (call_type 0): um DID por ramal
    awk -F';' 'NR > 1 && $1 ~ /^[0-9]+$/ {
        printf "INSERT INTO dids (number, accountid, inc, extensions, status, call_type, leg_timeout, product_id, always, always_destination, user_busy, user_busy_destination, user_not_registered, user_not_registered_destination, no_answer, no_answer_destination, failover_extensions, last_modified_date) VALUES (%c%s%c,2,60,%c%s%c,0,0,30,0,0,%c%c,0,%c%c,0,%c%c,0,%c%c,%c%c,NOW());\n",
            39, $3, 39, 39, $1, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39 }' "${devices}"
    # por ultimo: o SBC espera este perfil para subir o FreeSWITCH.
    # perfil dos devices: IP interno (dispatcher setid 2); ext-rtp-ip conforme o ambiente
    # (127.0.0.1 no Docker Desktop, que publica as portas de RTP no macOS)
    cat <<SQL
DELETE FROM sip_profiles WHERE id = 100 OR name = '${dev_profile}';
INSERT INTO sip_profiles (id, name, sip_ip, sip_port, profile_data, created_date, last_modified_date, accountid, status)
  SELECT 100, '${dev_profile}', '\$\${local_ip_v4}', '5080',
    JSON_SET(profile_data, '\$."rtp-ip"', '\$\${local_ip_v4}', '\$."ext-rtp-ip"', '${dev_rtp}',
      '\$."ext-sip-ip"', '\$\${local_ip_v4}', '\$."presence-hosts"', '\$\${domain},\$\${local_ip_v4}'),
    NOW(), NOW(), 0, 0
  FROM sip_profiles WHERE id = 1;
SQL
}
