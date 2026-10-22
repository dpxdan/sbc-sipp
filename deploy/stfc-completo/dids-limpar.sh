#!/usr/bin/env bash
#
# dids-limpar.sh - remove os DIDs de teste da campanha do STFC (WEB-1437)
#
# Uso (root no no 1 do banco, .161):
#   bash dids-limpar.sh contar  --conta ID
#   bash dids-limpar.sh remover --conta ID [--lote N] [--pausa S] [--incluir-modelo] [-y]
#
# Opcoes:
#   --conta ID          conta de teste (obrigatorio; na campanha de 21/10/2026: 211)
#   --lote N            DIDs por DELETE (padrao 5000, maximo 10000)
#   --pausa S           segundos entre lotes, para o PXC replicar sem flow control (padrao 1)
#   --incluir-modelo    remove tambem o DID modelo 5500000000000 (padrao: fica, para sair pela
#                       interface junto com o produto dele)
#   --banco NOME        banco do Flux (padrao flux)
#   --defaults-file F   credenciais do mysql (padrao: root pelo socket)
#   -y                  nao pede a confirmacao
#
# O que entra (todos os filtros juntos): DIDs da conta informada, numero 5500000xxxxxx (faixa
# ficticia, DDD 00), DIRECT-IP (call_type 2) com destino 200.159.177.165:5090 (atendedor do
# .165). Qualquer outro DID, inclusive na mesma faixa em outra conta, so aparece na contagem.
#
# Impacto (ESCRITA NO BANCO DE PRODUCAO): DELETE em lotes pela chave primaria; cada lote e um
# writeset replicado no PXC. Os CDRs das chamadas de teste ficam (historico da conta de teste).
# Sem reversao automatica: a recriacao e o sql/20-dids-create.sql.
# Codigos de saida: 0 ok, 2 uso, 3 conferencia falhou, 5 erro do mysql.

set -Eeuo pipefail
export LC_ALL=C

readonly PREFIXO=5500000 MODELO=5500000000000 DESTINO=200.159.177.165:5090 CALL_TYPE=2
readonly E_USAGE=2 E_CHECK=3 E_MYSQL=5

die() { local c=$1; shift; printf 'ERRO: %s\n' "$*" >&2; exit "${c}"; }
log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; }

ACAO=${1:-}
(($# > 0)) && shift
CONTA="" LOTE=5000 PAUSA=1 MODELO_TAMBEM=0 BANCO=flux DEFAULTS="" YES=0
while (($# > 0)); do
    case "$1" in
        --conta)          CONTA=${2:-}; shift 2 ;;
        --lote)           LOTE=${2:-}; shift 2 ;;
        --pausa)          PAUSA=${2:-}; shift 2 ;;
        --incluir-modelo) MODELO_TAMBEM=1; shift ;;
        --banco)          BANCO=${2:-}; shift 2 ;;
        --defaults-file)  DEFAULTS=${2:-}; shift 2 ;;
        -y)               YES=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "${E_USAGE}" "opcao invalida: $1" ;;
    esac
done

case "${ACAO}" in
    contar|remover) ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) die "${E_USAGE}" "acao invalida: ${ACAO} (contar ou remover)" ;;
esac
# Valores entram no SQL como literais: so digitos e nomes simples
[[ ${CONTA} =~ ^[1-9][0-9]{0,9}$ ]] || die "${E_USAGE}" "--conta obrigatorio (inteiro positivo)"
if ! [[ ${LOTE} =~ ^[0-9]+$ ]] || ((LOTE < 1 || LOTE > 10000)); then
    die "${E_USAGE}" "--lote entre 1 e 10000"
fi
[[ ${PAUSA} =~ ^[0-9]+$ ]] || die "${E_USAGE}" "--pausa em segundos (inteiro)"
[[ ${BANCO} =~ ^[A-Za-z0-9_]+$ ]] || die "${E_USAGE}" "--banco invalido"
[[ -z ${DEFAULTS} || -r ${DEFAULTS} ]] || die "${E_USAGE}" "--defaults-file ilegivel: ${DEFAULTS}"
command -v mysql >/dev/null 2>&1 || die "${E_USAGE}" "cliente mysql nao encontrado"

MYSQL=(mysql)
[[ -n ${DEFAULTS} ]] && MYSQL+=("--defaults-file=${DEFAULTS}")
MYSQL+=(-N -B "${BANCO}")

# sql TEXTO: executa e devolve o resultado (sem cabecalho). Literais _utf8mb3 com a mesma
# codificacao das colunas do Flux: comparar com utf8mb4 converteria a coluna e anularia o
# indice de dids.number (o mesmo problema da criacao dos DIDs).
sql() {
    "${MYSQL[@]}" -e "SET NAMES utf8mb4; $1" || die "${E_MYSQL}" "mysql falhou: ${1:0:120}"
}

FAIXA="number LIKE _utf8mb3'${PREFIXO}%'"
ALVO="accountid = ${CONTA} AND ${FAIXA} AND call_type = ${CALL_TYPE} AND extensions = _utf8mb3'${DESTINO}'"
((MODELO_TAMBEM)) || ALVO+=" AND number <> _utf8mb3'${MODELO}'"

contar() {
    local conta_ok alvo modelo outros_conta outras_contas
    conta_ok=$(sql "SELECT COUNT(*) FROM accounts WHERE id = ${CONTA}")
    alvo=$(sql "SELECT COUNT(*) FROM dids WHERE ${ALVO}")
    modelo=$(sql "SELECT COUNT(*) FROM dids WHERE accountid = ${CONTA} AND number = _utf8mb3'${MODELO}'")
    outros_conta=$(sql "SELECT COUNT(*) FROM dids WHERE accountid = ${CONTA} AND IFNULL((${ALVO}), 0) = 0")
    outras_contas=$(sql "SELECT COUNT(*) FROM dids WHERE ${FAIXA} AND accountid <> ${CONTA}")
    printf '  %-48s %s\n' "conta ${CONTA} existe" "$([[ ${conta_ok} == 1 ]] && echo sim || echo NAO)" \
        "DIDs a remover" "${alvo}" \
        "DID modelo ${MODELO} na conta" "${modelo} ($( ((MODELO_TAMBEM)) && echo 'entra na remocao' || echo 'fica'))" \
        "outros DIDs da conta, modelo incluso (ficam)" "${outros_conta}" \
        "DIDs ${PREFIXO}xxxxxx de outras contas (nao entram)" "${outras_contas}"
    [[ ${conta_ok} == 1 ]] || die "${E_CHECK}" "conta ${CONTA} inexistente"
    ALVO_TOTAL=${alvo}
}

log "banco ${BANCO}, conta ${CONTA}: ${ACAO}"
contar
[[ ${ACAO} == contar ]] && exit 0

if ((ALVO_TOTAL == 0)); then
    log "nada a remover"
    exit 0
fi
if ((YES == 0)); then
    read -r -p "Remover ${ALVO_TOTAL} DIDs da conta ${CONTA} em lotes de ${LOTE}? Digite REMOVER: " resp
    [[ ${resp} == REMOVER ]] || die "${E_CHECK}" "cancelado"
fi

removidos=0
while :; do
    # ids pela chave da conta (indice de accountid); o DELETE e pela chave primaria e repete os
    # filtros, para nunca apagar fora do alvo
    ids=$(sql "SELECT id FROM dids WHERE ${ALVO} ORDER BY id LIMIT ${LOTE}" | paste -sd, -)
    [[ -n ${ids} ]] || break
    n=$(sql "DELETE FROM dids WHERE id IN (${ids}) AND ${ALVO}; SELECT ROW_COUNT();")
    removidos=$((removidos + n))
    log "lote: ${n} removidos (total ${removidos} de ${ALVO_TOTAL})"
    ((n > 0)) || die "${E_MYSQL}" "lote sem remocao: interrompido para conferencia"
    sleep "${PAUSA}"
done

log "fim: ${removidos} DIDs removidos"
contar
if ((MODELO_TAMBEM == 0)); then
    log "o DID modelo ${MODELO} ficou: remova pela interface (DIDs) para levar o produto junto, e desative a conta ${CONTA}"
fi
