-- deploy/stfc-completo/sql/95-dids-remove.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Preferir o deploy/stfc-completo/dids-limpar.sh: conta antes, pede confirmacao, remove os
-- clones em lotes pela chave primaria (sem repetir a mao) e mantem o DID modelo para sair pela
-- interface com o produto. Este SQL fica como alternativa manual.
--
-- Remove os DIDs de teste ao fim da campanha (inclusive o modelo), em lotes de 10.000.
-- Repita ate "removidos = 0". So apaga a faixa ficticia 5500000xxxxxx da conta de teste,
-- DIRECT-IP com destino no atendedor do .165.
--
-- Uso (no no 1 do banco):
--   { echo "SET @conta = <ID>;"; cat 95-dids-remove.sql; } | mysql flux

-- Collation: as tabelas do Flux usam utf8mb4_general_ci/utf8_general_ci e o padrao do MySQL
-- 8.4 (utf8mb4_0900_ai_ci) faria as variaveis abaixo falharem com "Illegal mix of collations".
SET NAMES utf8mb4 COLLATE utf8mb4_general_ci;

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
-- pelo indice de accountid: comparar dids.number (utf8) com variavel utf8mb4 varreria a tabela
SELECT COUNT(*) AS restantes_na_conta FROM dids
 WHERE accountid = @conta AND @conta > 0 AND number LIKE CONCAT(@prefixo, '%');
