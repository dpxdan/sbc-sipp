-- deploy/stfc-completo/sql/95-dids-remove.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Remove os DIDs de teste ao fim da campanha (inclusive o modelo), em lotes de 10.000.
-- Repita ate "removidos = 0". So apaga a faixa ficticia 5500000xxxxxx da conta de teste,
-- DIRECT-IP com destino no atendedor do .165.
--
-- Uso (no no 1 do banco):
--   { echo "SET @conta = <ID>;"; cat 95-dids-remove.sql; } | mysql flux

SET @conta   = IFNULL(@conta, 0);
SET @prefixo = '5500000';
SET @destino = '200.159.177.165:5090';

-- Conferencia com o mesmo filtro do DELETE (esperado: o total criado, ate 100.000)
SELECT COUNT(*) AS a_remover FROM dids
 WHERE accountid = @conta AND @conta > 0
   AND number LIKE CONCAT(@prefixo, '%')
   AND call_type = 2 AND extensions = @destino;

DELETE FROM dids
 WHERE accountid = @conta AND @conta > 0
   AND number LIKE CONCAT(@prefixo, '%')
   AND call_type = 2 AND extensions = @destino
 LIMIT 10000;

SELECT ROW_COUNT() AS removidos;
SELECT COUNT(*) AS restantes_na_faixa FROM dids WHERE number LIKE CONCAT(@prefixo, '%');
