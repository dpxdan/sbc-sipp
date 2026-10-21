-- deploy/stfc-completo/sql/90-opensips-address-remove.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Remove a liberacao do gerador (.165) no OpenSIPS ao fim do teste (ou ao abortar). Apaga so
-- a linha criada pelo 10-opensips-address-add.sql (context_info = 'flux-loadtest').
-- Depois, no sbc-stfc-1:
--   opensips-cli -x mi address_reload
--   opensips-cli -x mi address_dump        (sem 200.159.177.165)

SET @gerador = '200.159.177.165';

-- Conferencia com o mesmo filtro do DELETE: esperado 1 linha (0 = ja removido)
SELECT COUNT(*) AS a_remover FROM address
 WHERE grp = 10 AND ip = @gerador AND context_info = 'flux-loadtest';

DELETE FROM address
 WHERE grp = 10 AND ip = @gerador AND context_info = 'flux-loadtest';

SELECT ROW_COUNT() AS removidos;
SELECT id, grp, ip, mask, port, proto, context_info FROM address WHERE ip = @gerador;
