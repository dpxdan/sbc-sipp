-- deploy/stfc-completo/sql/20-dids-create.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Lote de DIDs DIRECT-IP da conta de teste, clonados do DID modelo criado pela interface
-- (todas as colunas do modelo, exceto id e number). Assim o lote fica identico ao que a
-- interface gravaria, qualquer que seja o schema de producao.
--
-- Pre-requisitos (README do deploy, secao 4.2):
--   - conta de teste ativa, SEM tarifa, credito alto, maxchannels 0 (sem limite);
--   - DID modelo 5500000000000 nessa conta, DIRECT-IP, destino 200.159.177.165:5090.
--
-- Uso (no no 1 do banco). Primeiro um lote de validacao com 10 DIDs:
--   { echo "SET @conta = <ID>; SET @inicio = 1; SET @lote = 10;"; cat 20-dids-create.sql; } | mysql flux
-- Depois lotes de 10.000 (numeros ja criados sao pulados), @inicio = 1, 10001, 20001 ... 90001:
--   { echo "SET @conta = <ID>; SET @inicio = 1;"; cat 20-dids-create.sql; } | mysql flux
-- Numeros: 5500000 + 6 digitos (5500000000001 a 5500000099999). DDD 00 nao existe.
--
-- Impacto: INSERT de ate 10.000 linhas em dids por execucao (writeset moderado no PXC; rode
-- os lotes um por vez). Cada chamada do teste gera CDR na conta de teste. Reversao:
-- 95-dids-remove.sql.

SET @conta   = IFNULL(@conta, 0);
SET @inicio  = IFNULL(@inicio, 1);
SET @lote    = LEAST(IFNULL(@lote, 10000), 10000);   -- comece com @lote = 10 para validar
SET @maximo  = 99999;
SET @prefixo = '5500000';
SET @modelo  = '5500000000000';
SET @destino = '200.159.177.165:5090';
SET SESSION cte_max_recursion_depth = 20000;
-- a lista de colunas da dids passa do limite padrao do GROUP_CONCAT (1024 caracteres)
SET SESSION group_concat_max_len = 65535;

-- Conferencia: o modelo precisa existir na conta de teste, DIRECT-IP para o atendedor
SELECT COUNT(*) INTO @modelo_ok FROM dids
 WHERE number = @modelo AND accountid = @conta AND @conta > 0 AND call_type = 2 AND extensions = @destino;
SELECT @conta AS conta, @inicio AS inicio, LEAST(@inicio + @lote - 1, @maximo) AS fim,
       @modelo_ok AS modelo_ok,
       (SELECT COUNT(*) FROM dids WHERE number LIKE CONCAT(@prefixo, '%')) AS faixa_antes;

-- Colunas do modelo (exceto id e number), lidas do schema em uso
SELECT GROUP_CONCAT(CONCAT('`', column_name, '`') ORDER BY ordinal_position),
       GROUP_CONCAT(CONCAT('d.`', column_name, '`') ORDER BY ordinal_position)
  INTO @cols, @cols_d
  FROM information_schema.columns
 WHERE table_schema = DATABASE() AND table_name = 'dids' AND column_name NOT IN ('id', 'number');

-- Sem modelo valido (@modelo_ok = 0) o SELECT nao retorna linhas e nada e inserido.
-- Numeros ja existentes sao pulados (NOT EXISTS), entao repetir um lote nao duplica.
SET @sql = CONCAT(
  'INSERT INTO dids (`number`, ', @cols, ') ',
  'WITH RECURSIVE seq (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < ', @lote - 1, ') ',
  'SELECT CONCAT(@prefixo, LPAD(seq.n + @inicio, 6, ''0'')), ', @cols_d, ' ',
  'FROM seq CROSS JOIN dids d ',
  'WHERE d.number = @modelo AND d.accountid = @conta AND @modelo_ok = 1 ',
  '  AND seq.n + @inicio <= @maximo ',
  '  AND NOT EXISTS (SELECT 1 FROM dids x WHERE x.number = CONCAT(@prefixo, LPAD(seq.n + @inicio, 6, ''0'')))');
PREPARE ins FROM @sql;
EXECUTE ins;
SELECT ROW_COUNT() AS inseridos;
DEALLOCATE PREPARE ins;

SELECT accountid, call_type, extensions, COUNT(*) AS dids_na_faixa
  FROM dids WHERE number LIKE CONCAT(@prefixo, '%')
 GROUP BY accountid, call_type, extensions;
