# shellcheck shell=bash
#
# install/prepare.sh - modo "prepare" do flux-host.sh (WEB-1437): pre-requisitos do
# flux-loadtest em servidores existentes, como os do STFC (README, secao 6).
#
# Nunca instala, atualiza, reconfigura ou reinicia FreeSWITCH, OpenSIPS ou MySQL/PXC, e nao
# toca em datadir, vhosts ou pools existentes. Cada alteracao passa por:
#   1. plano (diff do arquivo; conteudo com senha omitido), sem alterar nada;
#   2. confirmacao (palavra SIM, ou -y), ou parada com --dry-run;
#   3. backup em /var/backups/flux-loadtest/<data>/ e validacao (visudo -cf, nginx -t,
#      php-fpm7.3 -t), com restauracao do backup se a validacao falhar.
# A unica acao em servico e o reload (graceful) do nginx e do PHP-FPM com --apply-status.
#
# Biblioteca para "source" pelo flux-host.sh (log, warn, die, ROLES, has_req, DRY_RUN,
# ASSUME_YES, MONITOR_PASS_FILE, CREATE_DB_USER, APPLY_STATUS).

readonly PREP_SUDOERS=/etc/sudoers.d/flux-loadtest
readonly PREP_MYCNF=/etc/mysql/flux-loadtest.cnf
readonly PREP_NGINX_CONF=/etc/nginx/conf.d/flux-loadtest-status.conf
readonly PREP_FPM_POOL_DIR=/etc/php/7.3/fpm/pool.d
readonly PREP_FPM_CONF=${PREP_FPM_POOL_DIR}/zz-flux-loadtest.conf
readonly PREP_ZBX_BIN=/usr/local/sbin/flux-loadtest-zbx
readonly PREP_ZBX_SUDOERS=/etc/sudoers.d/flux-loadtest-zbx
readonly PREP_ZBX_AGENT_CONF=/etc/zabbix/zabbix_agentd.conf
# Diretorio do include: o do Include= do zabbix_agentd.conf (pacote oficial: zabbix_agentd.d;
# pacote do Debian: zabbix_agentd.conf.d). Definido por zbx_include_resolve.
readonly PREP_ZBX_INCLUDE_NAME=flux-loadtest.conf
readonly PREP_ZBX_INCLUDE_DEFAULT_DIR=/etc/zabbix/zabbix_agentd.d
PREP_ZBX_INCLUDE_DIR=${PREP_ZBX_INCLUDE_DEFAULT_DIR}
PREP_ZBX_INCLUDE=${PREP_ZBX_INCLUDE_DIR}/${PREP_ZBX_INCLUDE_NAME}
readonly PREP_ZBX_PROFILES=/etc/flux-loadtest/profiles.d
readonly PREP_ZBX_RELEASE=https://repo.zabbix.com/zabbix/7.2/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.2+debian12_all.deb

PREP_APPLY=0
PREP_CHANGES=0
PREP_CHANGED=0
PREP_BACKUP_DIR=""
PREP_RELOAD=()
PREP_RESTART_AGENT=0

prep_backup() {
    local f=$1
    [[ -e ${f} ]] || return 0
    install -d -m 0700 "${PREP_BACKUP_DIR}$(dirname "${f}")"
    cp -a "${f}" "${PREP_BACKUP_DIR}${f}"
}

# Volta o arquivo ao estado anterior (backup) ou o remove, se era novo
prep_restore() {
    local f=$1
    if [[ -e ${PREP_BACKUP_DIR}${f} ]]; then
        cp -a "${PREP_BACKUP_DIR}${f}" "${f}"
    else
        rm -f "${f}"
    fi
}

# prep_file DESTINO MODO DONO:GRUPO SECRETO(0|1) [VALIDADOR...] < conteudo
# PREP_CHANGED=1 quando o arquivo muda (ou mudaria, no plano). Validador que recebe o proprio
# DESTINO (visudo -cf) roda antes, no arquivo temporario; os demais (nginx -t) depois de gravar.
prep_file() {
    local dst=$1 mode=$2 owner=$3 secret=$4 tmp cur=""
    shift 4
    PREP_CHANGED=0
    tmp=$(mktemp)
    cat > "${tmp}"
    [[ -f ${dst} ]] && cur=$(stat -c '%a %U:%G' "${dst}")
    if [[ -f ${dst} ]] && cmp -s "${tmp}" "${dst}" && [[ ${cur} == "${mode#0} ${owner}" ]]; then
        log "ok: ${dst} sem alteracao"
        rm -f "${tmp}"
        return 0
    fi
    PREP_CHANGED=1
    PREP_CHANGES=$((PREP_CHANGES + 1))
    if ((PREP_APPLY == 0)); then
        log "alterar: ${dst} (${mode} ${owner}$([[ -n ${cur} ]] && printf ', hoje %s' "${cur}"))"
        if ((secret)); then
            printf '    (conteudo com senha omitido)\n'
        else
            diff -u "$([[ -f ${dst} ]] && printf '%s' "${dst}" || printf /dev/null)" "${tmp}" | sed '1,2d; s/^/    /' || true
        fi
        rm -f "${tmp}"
        return 0
    fi
    local -a pre=("${@//"${dst}"/"${tmp}"}")
    if [[ " $* " == *" ${dst} "* ]] && ! "${pre[@]}" >/dev/null 2>&1; then
        rm -f "${tmp}"
        die "validacao falhou para ${dst} ($*); nada foi gravado"
    fi
    prep_backup "${dst}"
    install -d -m 0755 "$(dirname "${dst}")"
    install -m "${mode}" -o "${owner%%:*}" -g "${owner##*:}" "${tmp}" "${dst}"
    rm -f "${tmp}"
    if (($# > 0)) && ! "$@" >/dev/null 2>&1; then
        prep_restore "${dst}"
        die "validacao falhou para ${dst} ($*); arquivo anterior restaurado"
    fi
    log "gravado: ${dst}"
}

# prep_cmd DESCRICAO COMANDO...: no plano so descreve; na aplicacao executa
prep_cmd() {
    local desc=$1
    shift
    PREP_CHANGES=$((PREP_CHANGES + 1))
    if ((PREP_APPLY == 0)); then
        log "executar: ${desc}"
        return 0
    fi
    log "${desc}"
    "$@" || die "falhou: ${desc}"
}

prep_reload() {
    local u
    for u in "${PREP_RELOAD[@]}"; do
        prep_cmd "reload do ${u} (graceful, sem derrubar conexoes)" systemctl reload "${u}"
    done
}

# --------------------------------------------------------------- papeis
prep_common() {
    local v
    if id loadtest >/dev/null 2>&1; then
        log "ok: usuario loadtest existe"
    else
        prep_cmd "criar o usuario loadtest (sem senha: o acesso e so pela chave do 'keys setup --via admin')" \
            useradd -m -s /bin/bash loadtest
    fi
    v=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    [[ ${v} == yes || ${PREP_APPLY} == 1 ]] || warn "relogio sem NTP sincronizado: os timestamps das amostras vem de cada servidor"
}

# sudoers do loadtest: fs_cli/opensips-cli dos papeis pedidos, somados aos que ja estao no arquivo
prep_sudoers() {
    local -a cmds=()
    local c p list
    if [[ -r ${PREP_SUDOERS} ]]; then
        while read -r c; do
            [[ -n ${c} ]] && cmds+=("${c}")
        done < <(sed -n 's/^loadtest ALL=(root) NOPASSWD: //p' "${PREP_SUDOERS}" | tr ',' '\n' | tr -d ' ')
    fi
    for c in freeswitch:fs_cli opensips:opensips-cli; do
        has_req "${c%%:*}" || continue
        p=$(command -v "${c#*:}" 2>/dev/null) || die "${c#*:} nao encontrado no PATH (papel ${c%%:*})"
        [[ " ${cmds[*]} " == *" ${p} "* ]] || cmds+=("${p}")
    done
    ((${#cmds[@]} > 0)) || return 0
    list=$(printf '%s, ' "${cmds[@]}")
    prep_file "${PREP_SUDOERS}" 0440 root:root 0 visudo -cf "${PREP_SUDOERS}" \
        < <(printf '# gerado pelo flux-host.sh prepare (flux-loadtest): coleta somente leitura\nloadtest ALL=(root) NOPASSWD: %s\n' "${list%, }")
}

# SQL pelo stdin: a senha nao aparece na lista de processos. CREATE USER e replicado no PXC.
prep_create_monitor() {
    printf "CREATE USER IF NOT EXISTS 'flux_monitor'@'localhost' IDENTIFIED BY '%s';\nGRANT PROCESS, REPLICATION CLIENT ON *.* TO 'flux_monitor'@'localhost';\n" "$1" \
        | mysql
}

prep_mysql() {
    local pass sock n
    [[ -n ${MONITOR_PASS_FILE} ]] || die "papel mysql: informe --monitor-pass-file (mesma senha nos dois nos)"
    [[ -r ${MONITOR_PASS_FILE} ]] || die "arquivo ilegivel: ${MONITOR_PASS_FILE}"
    [[ $(stat -c %a "${MONITOR_PASS_FILE}") == 600 ]] || die "${MONITOR_PASS_FILE} deve ter permissao 0600"
    pass=$(tr -d '[:space:]' < "${MONITOR_PASS_FILE}")
    [[ ${pass} =~ ^[A-Za-z0-9]{12,}$ ]] || die "senha do flux_monitor: alfanumerica, 12+ caracteres"
    mysqladmin ping >/dev/null 2>&1 || die "mysqld local sem resposta para o root (auth_socket)"
    sock=$(mysql -N -B -e 'SELECT @@socket' 2>/dev/null) || die "nao foi possivel ler @@socket"
    prep_file "${PREP_MYCNF}" 0600 loadtest:loadtest 1 \
        < <(printf '[client]\nuser=flux_monitor\npassword=%s\nsocket=%s\n' "${pass}" "${sock}")
    n=$(mysql -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE user = 'flux_monitor' AND host = 'localhost'")
    if [[ ${n} != 0 ]]; then
        log "ok: usuario flux_monitor@localhost existe (a senha nao e alterada)"
    elif ((CREATE_DB_USER)); then
        prep_cmd "criar flux_monitor@localhost com PROCESS e REPLICATION CLIENT (replicado para o cluster)" \
            prep_create_monitor "${pass}"
    else
        warn "flux_monitor@localhost nao existe: use --create-db-user em UM no (o PXC replica para o outro)"
    fi
}

# Pool unico do PHP-FPM 7.3: nome e endereco (listen)
fpm_pool() {
    local -a names
    mapfile -t names < <(grep -h '^\[[A-Za-z0-9_.-]*\]' "${PREP_FPM_POOL_DIR}"/*.conf 2>/dev/null | tr -d '[]' | sort -u | grep -vx global)
    ((${#names[@]} == 1)) || return 1
    FPM_POOL=${names[0]}
    FPM_LISTEN=$(awk -v p="[${FPM_POOL}]" '$0 == p { s = 1; next } /^\[/ { s = 0 } s && $1 == "listen" { sub(/^[^=]*=[[:space:]]*/, ""); v = $0 } END { print v }' "${PREP_FPM_POOL_DIR}"/*.conf)
    [[ -n ${FPM_LISTEN} ]]
}

prep_web() {
    local ngx_ok=0 fpm_ok=0 pass_to="" fpm_loc=""
    FPM_POOL="" FPM_LISTEN=""
    curl -fsS -m 3 http://127.0.0.1/nginx_status >/dev/null 2>&1 && ngx_ok=1
    curl -fsS -m 3 'http://127.0.0.1/fpm-status?json' >/dev/null 2>&1 && fpm_ok=1
    if ((ngx_ok && fpm_ok)); then
        log "ok: nginx_status e fpm-status respondem em 127.0.0.1"
        return 0
    fi
    if fpm_pool; then
        [[ ${FPM_LISTEN} == /* ]] && pass_to="unix:${FPM_LISTEN}" || pass_to=${FPM_LISTEN}
        fpm_loc=$(printf '    location = /fpm-status {\n        include fastcgi_params;\n        fastcgi_param SCRIPT_NAME /fpm-status;\n        fastcgi_param SCRIPT_FILENAME /fpm-status;\n        fastcgi_pass %s;\n    }\n' "${pass_to}")
    else
        warn "PHP-FPM 7.3 sem pool unico em ${PREP_FPM_POOL_DIR}: fpm-status fica de fora (configure pm.status_path a mao)"
    fi
    if ((APPLY_STATUS == 0)); then
        log "status do nginx/PHP-FPM ausente: opcional (colunas ngx_*/fpm_* vazias). Para criar, repita com --apply-status:"
        printf '    %s: server so em 127.0.0.1:80 com /nginx_status%s\n' "${PREP_NGINX_CONF}" "$([[ -n ${fpm_loc} ]] && printf ' e /fpm-status')"
        [[ -n ${FPM_POOL} ]] && printf '    %s: [%s] pm.status_path = /fpm-status\n' "${PREP_FPM_CONF}" "${FPM_POOL}"
        return 0
    fi
    # server proprio em 127.0.0.1:80: o vhost da aplicacao e o trafego externo nao mudam
    # (entrada por < <(...): prep_file roda neste shell e conta as alteracoes)
    prep_file "${PREP_NGINX_CONF}" 0644 root:root 0 nginx -t < <(
        printf '# gerado pelo flux-host.sh prepare (flux-loadtest): status so para 127.0.0.1\n'
        printf 'server {\n    listen 127.0.0.1:80;\n    server_name _;\n    access_log off;\n\n'
        printf '    location = /nginx_status {\n        stub_status;\n    }\n'
        [[ -n ${fpm_loc} ]] && printf '\n%s\n' "${fpm_loc}"
        printf '    location / {\n        return 404;\n    }\n}\n'
    )
    if ((PREP_CHANGED)); then PREP_RELOAD+=(nginx); fi
    if [[ -n ${FPM_POOL} ]]; then
        prep_file "${PREP_FPM_CONF}" 0644 root:root 0 php-fpm7.3 -t \
            < <(printf '; gerado pelo flux-host.sh prepare (flux-loadtest)\n[%s]\npm.status_path = /fpm-status\n' "${FPM_POOL}")
        if ((PREP_CHANGED)); then PREP_RELOAD+=(php7.3-fpm); fi
    fi
    return 0
}

prep_gen() {
    prep_cmd "papel gen do laboratorio no servidor de testes (pacotes, sysctl, limites)" \
        bash "${ROLES_DIR}/gen.sh"
}

# Repositorio oficial do Zabbix 7.2 (versao de producao) e o zabbix-agent (agentd)
prep_install_agent() {
    local tmp
    tmp=$(mktemp -d)
    curl -fsSLo "${tmp}/zabbix-release.deb" "${PREP_ZBX_RELEASE}" || { rm -rf "${tmp}"; return 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${tmp}/zabbix-release.deb"
    rm -rf "${tmp}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zabbix-agent sudo python3
}

# Diretorio que o agentd le para o nosso include: o primeiro Include= que seja um diretorio ou
# DIR/*.conf (o nome flux-loadtest.conf precisa casar). Sem conf (antes de instalar): o padrao do
# pacote oficial. Retorna 1 se o conf existe e nenhum Include serve.
zbx_include_resolve() {
    local inc dir
    PREP_ZBX_INCLUDE_DIR=${PREP_ZBX_INCLUDE_DEFAULT_DIR}
    PREP_ZBX_INCLUDE=${PREP_ZBX_INCLUDE_DIR}/${PREP_ZBX_INCLUDE_NAME}
    [[ -r ${PREP_ZBX_AGENT_CONF} ]] || return 0
    while IFS= read -r inc; do
        inc=${inc%$'\r'}
        inc=${inc%"${inc##*[![:space:]]}"}
        case "${inc}" in
            */\*.conf) dir=${inc%/*} ;;
            */\*) dir=${inc%/*} ;;
            *) [[ -d ${inc} ]] || continue; dir=${inc%/} ;;
        esac
        [[ ${dir} == /* ]] || continue
        PREP_ZBX_INCLUDE_DIR=${dir}
        PREP_ZBX_INCLUDE=${dir}/${PREP_ZBX_INCLUDE_NAME}
        return 0
    done < <(sed -n 's/^[[:space:]]*Include[[:space:]]*=[[:space:]]*//p' "${PREP_ZBX_AGENT_CONF}")
    return 1
}

# Linhas ativas do agentd (conf principal + includes, menos o nosso): PARAMETRO=valor.
# Arquivo sem o parametro nao e erro (pipefail): sempre retorna 0.
zbx_agent_lines() {
    local f
    for f in "${PREP_ZBX_AGENT_CONF}" "${PREP_ZBX_INCLUDE_DIR}"/*.conf; do
        [[ -r ${f} && ${f} != "${PREP_ZBX_INCLUDE}" ]] || continue
        grep -hE "^[[:space:]]*$1=" "${f}" 2>/dev/null | sed 's/^[[:space:]]*//' || true
    done
    return 0
}

# Agent ja monitorado: avisa o que anularia a restricao do include ou impediria os scripts
zbx_agent_audit() {
    local servers
    servers=$(zbx_agent_lines Server | cut -d= -f2- | tr -d ' ')
    [[ -n ${servers} ]] || warn "agentd sem Server=: o Zabbix nao consegue executar os scripts (modo passivo)"
    [[ -z ${servers} ]] || log "agentd: Server=${servers} (o Zabbix server/proxy do host precisa estar aqui)"
    if zbx_agent_lines AllowKey | grep -qE '^AllowKey=system\.run\[\*\]'; then
        warn "o agentd ja tem AllowKey=system.run[*]: a primeira regra vale e a restricao por perfil fica sem efeito"
    fi
    if zbx_agent_lines EnableRemoteCommands | grep -qE '=1'; then
        warn "o agentd tem EnableRemoteCommands=1 (obsoleto): equivale a liberar qualquer system.run"
    fi
    log "agentd: include do flux-loadtest em ${PREP_ZBX_INCLUDE} (Include= do ${PREP_ZBX_AGENT_CONF})"
}

# Servidor de testes: zabbix-agentd + flux-loadtest-zbx para o disparo pelo Zabbix (README 19.6).
# Agent ja instalado (servidor monitorado): o zabbix_agentd.conf nao e alterado; so o include,
# o wrapper e o sudoers sao gravados.
prep_zabbix_agent() {
    local src="${REPO_DIR}/bin/flux-loadtest-zbx" conf
    [[ -r ${src} ]] || die "wrapper ausente no repositorio: ${src}"
    zbx_include_resolve || die "${PREP_ZBX_AGENT_CONF} sem Include= de diretorio (DIR/*.conf): o include do flux-loadtest nao seria lido; acrescente um e repita"
    # estado antes da primeira passada (o plano e a aplicacao decidem igual)
    if [[ -z ${PREP_ZBX_PREEXIST:-} ]]; then
        if dpkg -s zabbix-agent >/dev/null 2>&1; then PREP_ZBX_PREEXIST=1; else PREP_ZBX_PREEXIST=0; fi
    fi
    if ((PREP_ZBX_PREEXIST)); then
        log "ok: zabbix-agent ja instalado ($(dpkg-query -W -f '${Version}' zabbix-agent)): ${PREP_ZBX_AGENT_CONF} nao sera alterado"
        if [[ -n ${ZBX_SERVER} && ${PREP_APPLY} == 0 ]]; then
            warn "--zabbix-server ignorado: o agent ja e monitorado e o Server/ServerActive dele ficam como estao"
        fi
        if ((PREP_APPLY == 0)); then zbx_agent_audit; fi
    else
        [[ -n ${ZBX_SERVER} ]] || die "zabbix-agent ausente: informe --zabbix-server IP para instalar e configurar"
        prep_cmd "instalar o zabbix-agent 7.2 (repo.zabbix.com)" prep_install_agent
    fi
    prep_file "${PREP_ZBX_BIN}" 0755 root:root 0 < "${src}"
    if [[ ! -d ${PREP_ZBX_PROFILES} ]]; then
        prep_cmd "criar ${PREP_ZBX_PROFILES} (perfis: profiles/*.conf.example)" install -d -m 0755 "${PREP_ZBX_PROFILES}"
    fi
    prep_file "${PREP_ZBX_SUDOERS}" 0440 root:root 0 visudo -cf "${PREP_ZBX_SUDOERS}" \
        < <(printf '# gerado pelo flux-host.sh prepare zabbix-agent: disparo do flux-loadtest pelo Zabbix\n# O wrapper valida perfil e argumentos; nenhum outro comando para o usuario zabbix.\nzabbix ALL=(root) NOPASSWD: %s\n' "${PREP_ZBX_BIN}")
    # sem o agent instalado (plano), o restante depende dele: para aqui
    if ((PREP_APPLY == 0)) && ! dpkg -s zabbix-agent >/dev/null 2>&1; then
        log "plano: depois da instalacao, ${PREP_ZBX_INCLUDE} e Server=${ZBX_SERVER} em ${PREP_ZBX_AGENT_CONF}"
        PREP_CHANGES=$((PREP_CHANGES + 2))
        return 0
    fi
    if [[ -n ${ZBX_SERVER} ]] && ((PREP_ZBX_PREEXIST == 0)); then
        # agent instalado agora: so o modo passivo: Server (quem consulta e executa) e sem ServerActive
        prep_file "${PREP_ZBX_AGENT_CONF}" 0644 root:root 0 zabbix_agentd -T -c "${PREP_ZBX_AGENT_CONF}" \
            < <(sed -E -e "s/^Server=.*/Server=${ZBX_SERVER}/" \
                       -e 's/^ServerActive=(.*)/# ServerActive=\1   # desativado pelo flux-host.sh (so passivo)/' \
                       "${PREP_ZBX_AGENT_CONF}")
        if ((PREP_CHANGED)); then PREP_RESTART_AGENT=1; fi
    fi
    # AllowKey exato por perfil: regenerar quando os perfis mudam
    conf=$(FLT_ZBX_RUNNER_CONF=/etc/flux-loadtest/zabbix-runner.conf bash "${src}" agent-conf) \
        || die "flux-loadtest-zbx agent-conf falhou (perfis invalidos?)"
    prep_file "${PREP_ZBX_INCLUDE}" 0644 root:root 0 zabbix_agentd -T -c "${PREP_ZBX_AGENT_CONF}" <<< "${conf}"
    if ((PREP_CHANGED)); then PREP_RESTART_AGENT=1; fi
    if ! grep -q '^ZABBIX_ENABLED=1' "${PREP_ZBX_PROFILES}"/*.conf 2>/dev/null; then
        warn "nenhum perfil com ZABBIX_ENABLED=1 em ${PREP_ZBX_PROFILES}: copie de ${REPO_DIR}/profiles/ e repita"
    fi
    if ((PREP_RESTART_AGENT)); then
        prep_cmd "restart do zabbix-agent (le o include novo; so no servidor de testes)" systemctl restart zabbix-agent
    fi
}

prep_pass() {
    local r
    PREP_CHANGES=0
    PREP_RELOAD=()
    PREP_RESTART_AGENT=0
    prep_common
    if has_req freeswitch || has_req opensips; then
        prep_sudoers
    fi
    for r in "${ROLES[@]}"; do
        case "${r}" in
            mysql) prep_mysql ;;
            web)   prep_web ;;
            gen)   prep_gen ;;
            zabbix-agent) prep_zabbix_agent ;;
        esac
    done
    ((${#PREP_RELOAD[@]} == 0)) || prep_reload
}

cmd_prepare() {
    local ans
    log "$(hostname): prepare ${ROLES[*]} (plano; nada e alterado nesta etapa)"
    PREP_APPLY=0
    prep_pass
    if ((PREP_CHANGES == 0)); then
        log "nada a fazer"
        return 0
    fi
    if ((DRY_RUN)); then
        log "--dry-run: ${PREP_CHANGES} alteracao(oes) planejada(s), nada aplicado"
        return 0
    fi
    if ((ASSUME_YES == 0)); then
        read -r -p "Aplicar ${PREP_CHANGES} alteracao(oes) em $(hostname)? Digite SIM: " ans
        [[ ${ans} == SIM ]] || die "cancelado"
    fi
    PREP_BACKUP_DIR="/var/backups/flux-loadtest/$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "${PREP_BACKUP_DIR}"
    PREP_APPLY=1
    prep_pass
    log "aplicado; backups em ${PREP_BACKUP_DIR}. Conferir: $0 check ${ROLES[*]}"
}
