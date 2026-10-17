-- deploy/stfc-fs02/sql/10-acl-lb-add.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Libera o gerador (.165) na ACL "default" do FreeSWITCH, pela mesma chave usada pelo
-- OpenSIPS (acl_lb_networks), para o .162 aceitar os INVITEs diretos.
--
-- Impacto:
--   - A chave e global: vale para todo FS que fizer "reloadacl" ou reiniciar enquanto ela
--     estiver assim. Recarregue SO no .162 e reverta com 90-acl-lb-restore.sql no fim.
--   - acl_lb_networks tambem alimenta a loopback.auto (Event Socket) do FS.
--   - Por desenho do Flux o no web nao envia chamadas: esta liberacao e temporaria.
--
-- Antes: guarde o valor atual (o restore remove so a entrada do .165, mas o registro serve
-- de prova do estado original):
--   mysql -N -B -e "SELECT value FROM \`system\` WHERE name = 'acl_lb_networks'" flux > /root/acl_lb_networks.antes
-- Depois, no .162:  fs_cli -x reloadacl  e  fs_cli -x 'acl 200.159.177.165 default'  (true)

SET @gerador = '200.159.177.165/32';

SELECT name, value FROM `system` WHERE name = 'acl_lb_networks';

-- Idempotente: nao duplica a entrada; chave inexistente = 0 linhas (pare e confira 00-verificacao.sql)
UPDATE `system`
   SET value = IF(value IS NULL OR TRIM(value) = '', @gerador, CONCAT(TRIM(TRAILING ',' FROM value), ',', @gerador))
 WHERE name = 'acl_lb_networks'
   AND FIND_IN_SET(@gerador, REPLACE(IFNULL(value, ''), ' ', '')) = 0;

SELECT ROW_COUNT() AS linhas_alteradas;
SELECT name, value FROM `system` WHERE name = 'acl_lb_networks';
