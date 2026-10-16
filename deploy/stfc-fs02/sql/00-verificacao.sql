-- deploy/stfc-fs02/sql/00-verificacao.sql - SOMENTE LEITURA (WEB-1437)
-- Rodar no no 1 do banco antes de qualquer alteracao, antes e depois de cada degrau:
--   mysql flux < 00-verificacao.sql
-- Ajuste @conta (id da conta de teste) e @inicio (inicio da janela do teste).

SET @conta  = 0;                       -- PREENCHER: accounts.id da conta de teste
SET @inicio = NOW() - INTERVAL 1 DAY;  -- inicio do periodo para os CDRs
SET @gerador = '200.159.177.165';

-- 1. Chave da ACL dos balanceadores (migracao update-02-09-2026.sql). Sem linha aqui, o
--    xml_curl do .162 nao tem acl_lb_networks: NAO prossiga com 10-acl-lb-add.sql.
SELECT id, name, value, group_title, reseller_id
  FROM `system` WHERE name IN ('acl_lb_networks', 'acl_trusted_networks', 'opensips', 'opensips_domain');

-- 2. O gerador ja esta em alguma lista? (ip_map de contas ativas tambem entra na ACL default)
SELECT 'ip_map' AS origem, im.*
  FROM ip_map im WHERE im.ip = @gerador;

-- 3. Conta de teste: status, credito e limite de canais (nao podem limitar o teste)
SELECT id, number, status, deleted, balance, credit_limit, maxchannels, pricelist_id
  FROM accounts WHERE id = @conta;

-- 4. DIDs da conta: devem ser todos DIRECT-IP (call_type 2) para o atendedor do .165
SELECT call_type, status, extensions, COUNT(*) AS dids
  FROM dids WHERE accountid = @conta GROUP BY call_type, status, extensions;

-- 5. CDRs do teste (CALLER_ID do loadtest.conf) no periodo, por resultado
SELECT disposition, call_direction, COUNT(*) AS chamadas, SUM(billseconds) AS segundos,
       SUM(debit) AS debito, SUM(cost) AS custo
  FROM cdrs WHERE callerid LIKE '%551130009999%' AND callstart >= @inicio
 GROUP BY disposition, call_direction;
