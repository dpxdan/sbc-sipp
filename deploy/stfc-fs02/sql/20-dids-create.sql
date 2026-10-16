-- deploy/stfc-fs02/sql/20-dids-create.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Lote de DIDs DIRECT-IP (call_type 2) da conta de teste apontando para o atendedor do
-- gerador (200.159.177.165:5090). Cada chamada gera CDR e passa pelo billing.
--
-- Pre-requisitos (README do deploy, passo 3):
--   - conta de teste ativa, SEM tarifa, com credito e maxchannels que nao limitem o teste;
--   - prefixo ficticio que nenhuma operadora encaminhe (confira que nao existe:
--     SELECT COUNT(*) FROM dids WHERE number LIKE '<prefixo>%');
--   - crie antes UM DID DIRECT-IP pela interface nesta conta e compare as colunas com as do
--     INSERT (o schema de producao pode ter colunas a mais ou valores padrao diferentes).
--
-- Lote de 1.000 por execucao (writeset pequeno no PXC). Para o 10 CPS com hold 20 s
-- (~200 simultaneas), 1.000 DIDs bastam; repita mudando @inicio para mais.

SET @conta   = 0;                -- PREENCHER: accounts.id da conta de teste
SET @prefixo = '55519';          -- PREENCHER: prefixo ficticio (sem DIDs reais)
SET @inicio  = 0;                -- primeiro sufixo do lote (0, 1000, 2000...)
SET @destino = '200.159.177.165:5090';

SELECT COUNT(*) AS ja_existem FROM dids WHERE number LIKE CONCAT(@prefixo, '%');

INSERT INTO dids (number, accountid, inc, extensions, status, call_type, leg_timeout, product_id,
  always, always_destination, user_busy, user_busy_destination, user_not_registered,
  user_not_registered_destination, no_answer, no_answer_destination, failover_extensions, last_modified_date)
WITH RECURSIVE seq (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 999)
SELECT CONCAT(@prefixo, LPAD(n + @inicio, 8, '0')), @conta, 60,
  @destino, 0, 2, 30, 0, 0, '', 0, '', 0, '', 0, '', '', NOW()
FROM seq
WHERE @conta > 0;

SELECT ROW_COUNT() AS inseridos;
SELECT call_type, extensions, COUNT(*) FROM dids WHERE accountid = @conta GROUP BY call_type, extensions;

-- Lista para o gerador (no .165, somente leitura):
--   mysql -h 172.17.4.100 -N -B -e "SELECT number FROM dids WHERE accountid = <conta> AND status = 0 AND call_type = 2 AND extensions = '200.159.177.165:5090'" flux > /etc/flux-loadtest/dids.txt
