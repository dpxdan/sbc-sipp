-- deploy/stfc-fs02/sql/90-acl-lb-restore.sql - ESCRITA NO BANCO DE PRODUCAO (WEB-1437)
--
-- Remove o gerador (.165) de acl_lb_networks ao fim do teste (ou ao abortar). Remove so a
-- entrada 200.159.177.165/32; as demais ficam (os espacos entre virgulas sao normalizados).
-- Depois, no .162:  fs_cli -x reloadacl  e  fs_cli -x 'acl 200.159.177.165 default'  (false)
-- Compare o resultado com /root/acl_lb_networks.antes.

SET @gerador = '200.159.177.165/32';

UPDATE `system`
   SET value = TRIM(BOTH ',' FROM REPLACE(CONCAT(',', REPLACE(IFNULL(value, ''), ' ', ''), ','),
                                          CONCAT(',', @gerador, ','), ','))
 WHERE name = 'acl_lb_networks'
   AND FIND_IN_SET(@gerador, REPLACE(IFNULL(value, ''), ' ', '')) > 0;

SELECT ROW_COUNT() AS linhas_alteradas;
SELECT name, value FROM `system` WHERE name = 'acl_lb_networks';
