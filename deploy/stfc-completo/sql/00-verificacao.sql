-- deploy/stfc-completo/sql/00-verificacao.sql - SOMENTE LEITURA (WEB-1437)
-- Rodar no no 1 do banco antes de qualquer alteracao e entre os degraus:
--   mysql flux < 00-verificacao.sql
-- Parametros (opcional, pela linha de comando):
--   { echo "SET @conta = 123;"; cat 00-verificacao.sql; } | mysql flux

-- Collation: as tabelas do Flux usam utf8mb4_general_ci/utf8_general_ci e o padrao do MySQL
-- 8.4 (utf8mb4_0900_ai_ci) faria as variaveis abaixo falharem com "Illegal mix of collations".
SET NAMES utf8mb4 COLLATE utf8mb4_general_ci;

SET @conta   = IFNULL(@conta, 0);                 -- accounts.id da conta de teste
SET @inicio  = IFNULL(@inicio, CURDATE());          -- inicio da janela dos CDRs (padrao: hoje)
SET @gerador = '200.159.177.165';
SET @prefixo = '5500000';
SET @destino = '200.159.177.165:5090';

-- 1. OpenSIPS: o gerador no grupo 10 (operadoras) da tabela address (permissions, banco flux)
SELECT id, grp, ip, mask, port, proto, context_info
  FROM address WHERE ip = @gerador OR context_info = 'flux-loadtest';

-- 2. load_balancer do OpenSIPS: nos do pool e recursos (senha do event socket omitida)
SELECT id, group_id, dst_uri, REGEXP_REPLACE(resources, 'fs://[^@]*@', 'fs://***@') AS resources, probe_mode
  FROM load_balancer;

-- 3. O gerador ja esta em alguma ACL do FreeSWITCH? (nao deveria: o caminho e pelo OpenSIPS)
SELECT name, value FROM `system` WHERE name IN ('opensips', 'opensips_domain', 'acl_lb_networks');
SELECT 'ip_map' AS origem, im.* FROM ip_map im WHERE im.ip LIKE CONCAT(@gerador, '%');

-- 4. Conta de teste: status, credito e limite de canais (0 = sem limite)
SELECT id, number, status, deleted, balance, credit_limit, maxchannels, pricelist_id
  FROM accounts WHERE id = @conta;

-- 5. Faixa ficticia: so DIDs da conta de teste, todos DIRECT-IP para o atendedor
SELECT accountid, call_type, status, extensions, maxchannels, COUNT(*) AS dids
  FROM dids WHERE number LIKE CONCAT(@prefixo, '%')
 GROUP BY accountid, call_type, status, extensions, maxchannels;

-- 6. CDRs do teste (CALLER_ID do loadtest.conf) no periodo, por resultado. Debito e custo
--    precisam ser ZERO: com valor, a conta de teste tem tarifa (pare e corrija).
--    cdrs e grande: mantenha @inicio curto (padrao: hoje); o LIKE varre so a janela.
SELECT disposition, call_direction, COUNT(*) AS chamadas, SUM(billseconds) AS segundos,
       SUM(debit) AS debito, SUM(cost) AS custo
  FROM cdrs WHERE callerid LIKE '%550000009999%' AND callstart >= @inicio
 GROUP BY disposition, call_direction;
