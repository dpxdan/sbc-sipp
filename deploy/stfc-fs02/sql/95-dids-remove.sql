-- deploy/stfc-fs02/sql/95-dids-remove.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
-- Remove os DIDs de teste ao fim da campanha, em lotes de 1.000 (repita ate 0 linhas).
-- So apaga DIDs da conta de teste, do prefixo ficticio e com destino no atendedor do .165.

SET @conta   = 0;          -- PREENCHER: accounts.id da conta de teste
SET @prefixo = '55519';    -- PREENCHER: mesmo prefixo do 20-dids-create.sql

DELETE FROM dids
 WHERE accountid = @conta AND @conta > 0
   AND number LIKE CONCAT(@prefixo, '%')
   AND call_type = 2 AND extensions = '200.159.177.165:5090'
 LIMIT 1000;

SELECT ROW_COUNT() AS removidos;
