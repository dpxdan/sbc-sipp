#!/usr/bin/env bash
#
# fs-limites.sh - limites de sessoes do FreeSWITCH em runtime para o teste de carga (WEB-1437)
#
# Uso (root no sbc-stfc-1 e no sbc-stfc-02):
#   bash fs-limites.sh mostrar
#   bash fs-limites.sh aplicar <SPS> <MAX_SESSOES>
#   bash fs-limites.sh restaurar
#
# Impacto (FreeSWITCH ativo, com trafego real):
#   - "fsctl sps" e "fsctl max_sessions" valem na hora, sem restart e sem mexer no switch.conf.
#     Nao persistem: um restart do FreeSWITCH volta aos valores do switch.conf.
#   - Limites maiores deixam o FS aceitar mais chamadas (do teste e reais); se o servidor
#     saturar, chamadas reais podem degradar. O guard do flux-loadtest para a carga antes.
#   - "aplicar" grava os valores atuais em /root/flux-loadtest-fs-limites.antes (uma vez);
#     "restaurar" volta a eles e apaga o arquivo.

set -Eeuo pipefail
export LC_ALL=C

readonly SAVE=/root/flux-loadtest-fs-limites.antes
readonly MAX_SPS=2000 MAX_SESS=20000

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

((EUID == 0)) || die "rode como root"
command -v fs_cli >/dev/null 2>&1 || die "fs_cli nao encontrado"

fsx() { timeout 10 fs_cli -x "$1" 2>/dev/null; }

# Ultimo numero da resposta do fsctl ("+OK ...: N")
fsctl_val() {
    local out
    out=$(fsx "fsctl $1") || return 1
    grep -oE '[0-9]+' <<< "${out}" | tail -n 1
}

mostrar() {
    local sps max st
    st=$(fsx status) || die "fs_cli sem resposta (crie /root/.fs_cli_conf com a senha do event socket)"
    sps=$(fsctl_val sps) || die "fsctl sps falhou"
    max=$(fsctl_val max_sessions) || die "fsctl max_sessions falhou"
    printf '%s: sps=%s max_sessions=%s\n' "$(hostname)" "${sps}" "${max}"
    printf '%s\n' "${st}" | grep -E 'session\(s\)' | sed 's/^/  /'
    [[ -f ${SAVE} ]] && printf '  valores originais guardados em %s: %s\n' "${SAVE}" "$(tr '\n' ' ' < "${SAVE}")"
    return 0
}

aplicar() {
    local sps=${1:-} max=${2:-} cur_sps cur_max
    [[ ${sps} =~ ^[0-9]+$ && ${max} =~ ^[0-9]+$ ]] || die "uso: $0 aplicar <SPS> <MAX_SESSOES>"
    ((sps >= 1 && sps <= MAX_SPS)) || die "SPS fora de 1-${MAX_SPS}"
    ((max >= 1 && max <= MAX_SESS)) || die "MAX_SESSOES fora de 1-${MAX_SESS}"
    cur_sps=$(fsctl_val sps) || die "fsctl sps falhou (fs_cli sem resposta?)"
    cur_max=$(fsctl_val max_sessions) || die "fsctl max_sessions falhou"
    if [[ ! -f ${SAVE} ]]; then
        (umask 077 && printf 'sps=%s\nmax_sessions=%s\n' "${cur_sps}" "${cur_max}" > "${SAVE}")
        printf 'originais guardados em %s: sps=%s max_sessions=%s\n' "${SAVE}" "${cur_sps}" "${cur_max}"
    fi
    fsx "fsctl sps ${sps}" >/dev/null || die "fsctl sps ${sps} falhou"
    fsx "fsctl max_sessions ${max}" >/dev/null || die "fsctl max_sessions ${max} falhou"
    mostrar
}

restaurar() {
    local sps max
    [[ -r ${SAVE} ]] || die "${SAVE} ausente: nada a restaurar (confira com: $0 mostrar)"
    sps=$(awk -F= '$1 == "sps" { print $2 }' "${SAVE}")
    max=$(awk -F= '$1 == "max_sessions" { print $2 }' "${SAVE}")
    [[ ${sps} =~ ^[0-9]+$ && ${max} =~ ^[0-9]+$ ]] || die "${SAVE} invalido"
    fsx "fsctl sps ${sps}" >/dev/null || die "fsctl sps ${sps} falhou"
    fsx "fsctl max_sessions ${max}" >/dev/null || die "fsctl max_sessions ${max} falhou"
    rm -f "${SAVE}"
    printf 'restaurado: sps=%s max_sessions=%s\n' "${sps}" "${max}"
    mostrar
}

case "${1:-}" in
    mostrar)   mostrar ;;
    aplicar)   aplicar "${2:-}" "${3:-}" ;;
    restaurar) restaurar ;;
    *)         die "uso: $0 mostrar | aplicar <SPS> <MAX_SESSOES> | restaurar" ;;
esac
