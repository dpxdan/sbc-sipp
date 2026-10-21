-- deploy/stfc-completo/sql/10-opensips-address-add.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Libera o gerador (.165) como operadora no OpenSIPS: grupo 10 da tabela address (modulo
-- permissions, check_source_address(10) no opensips.cfg). As chamadas dele seguem o caminho
-- das operadoras: load_balancer -> FreeSWITCH -> dialplan Lua -> DID.
--
-- Impacto:
--   - So vale depois do "opensips-cli -x mi address_reload" no sbc-stfc-1 (sem restart).
--   - O .165 passa a ser origem confiavel por IP no OpenSIPS: qualquer INVITE dele e aceito
--     como operadora (inclusive para DIDs reais). Reverta com 90-opensips-address-remove.sql.
--   - Nao altera a ACL do FreeSWITCH (o FS continua aceitando so o OpenSIPS).
--
-- Depois, no sbc-stfc-1:
--   opensips-cli -x mi address_reload
--   opensips-cli -x mi address_dump        (grupo 10 com 200.159.177.165)

-- Collation: as tabelas do Flux usam utf8mb4_general_ci/utf8_general_ci e o padrao do MySQL
-- 8.4 (utf8mb4_0900_ai_ci) faria as variaveis abaixo falharem com "Illegal mix of collations".
SET NAMES utf8mb4 COLLATE utf8mb4_general_ci;

SET @gerador = '200.159.177.165';

SELECT id, grp, ip, mask, port, proto, context_info FROM address WHERE ip = @gerador;

-- Idempotente: so insere se o .165 ainda nao estiver no grupo 10
INSERT INTO address (grp, ip, mask, port, proto, context_info)
SELECT 10, @gerador, 32, 0, 'any', 'flux-loadtest'
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM address WHERE grp = 10 AND ip = @gerador);

SELECT ROW_COUNT() AS inseridos;
SELECT id, grp, ip, mask, port, proto, context_info FROM address WHERE ip = @gerador;
