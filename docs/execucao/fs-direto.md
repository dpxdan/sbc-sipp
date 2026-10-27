# FreeSWITCH direto, sem OpenSIPS

Valida o script e mede um nó isolado: o `load_balancer` não entra. Foi o formato do primeiro teste
em produção (carga direta no FS do `sbc-stfc-02`, a partir do `.165`).

## Configuração

No `loadtest.conf`, deixe vazios `OPENSIPS_HOST`, `DB_HOSTS` (ou mantenha, para coletar o banco) e
`WEB_HOST`, e aponte para o FS:

```
FS_HOSTS=200.159.177.162
SIP_TARGET=200.159.177.162:5070
```

Para o FS do `sbc-stfc-1`, use `200.159.177.163` com a porta `5070` (a `5060` é o OpenSIPS).

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 5 -H 20 -w 180 --label fs-direto
```

## Autorizar a origem no FS: `acl_lb_networks`

O perfil `default` do FS usa `apply-inbound-acl=default` e `auth-calls=true`. A lista `default` vem
do `xml_curl` (`load_acl` em `fs/lib/flux.xml.php`): `ip_map` das contas, gateways,
`opensips_domain` e `acl_lb_networks`.

Liberar a VM por `acl_lb_networks` faz a chamada seguir o mesmo caminho das que chegam pelo OpenSIPS
(operadora -> DID). Por `ip_map` na conta de teste, a chamada seria tratada como originação de
cliente: outro fluxo de dialplan, com risco de rota para operadora.

!!! warning "A chave é global"
    `acl_lb_networks` vale para todo FS que fizer `reloadacl` ou reiniciar enquanto ela estiver
    alterada, e também alimenta a `loopback.auto` (event socket). Recarregue só no FS alvo e
    reverta ao fim. Se o `flux.xml.php` do FS não tiver `acl_lb_networks` (versão anterior a
    02/09/2026), a liberação não tem efeito: pare e reavalie.

Guarde o valor atual (no nó 1 do banco):

```bash
mysql -N -B -e "SELECT value FROM \`system\` WHERE name = 'acl_lb_networks'" flux > /root/acl_lb_networks.antes
```

Adicionar o gerador (idempotente; troque o IP):

```sql
SET @gerador = '200.159.177.165/32';
UPDATE `system`
   SET value = IF(value IS NULL OR TRIM(value) = '', @gerador, CONCAT(TRIM(TRAILING ',' FROM value), ',', @gerador))
 WHERE name = 'acl_lb_networks'
   AND FIND_IN_SET(@gerador, REPLACE(IFNULL(value, ''), ' ', '')) = 0;
SELECT ROW_COUNT() AS linhas_alteradas;
```

`linhas_alteradas = 0` com a chave inexistente: pare e confira. No FS alvo:

```bash
fs_cli -x reloadacl
```

```bash
fs_cli -x 'acl 200.159.177.165 default'
```

O segundo comando precisa responder `true`.

Remover ao fim (só a entrada do gerador; as demais ficam):

```sql
SET @gerador = '200.159.177.165/32';
UPDATE `system`
   SET value = TRIM(BOTH ',' FROM REPLACE(CONCAT(',', REPLACE(IFNULL(value, ''), ' ', ''), ','),
                                          CONCAT(',', @gerador, ','), ','))
 WHERE name = 'acl_lb_networks'
   AND FIND_IN_SET(@gerador, REPLACE(IFNULL(value, ''), ' ', '')) > 0;
SELECT ROW_COUNT() AS linhas_alteradas;
```

Depois, `fs_cli -x reloadacl` no FS e `fs_cli -x 'acl 200.159.177.165 default'` deve responder
`false`. Compare o valor com `/root/acl_lb_networks.antes`.

## Limites do nó

Com bridge para o atendedor, cada chamada abre 2 sessões no FS. O teto prático é
`sessions-per-second / 2` em CPS e `max-sessions / 2` em simultâneas, dividido com o tráfego real.
Confira os valores em uso com `fs-limites.sh mostrar` antes de definir os degraus e, no disparo pelo
Zabbix, ajuste `ZBX_MAX_CPS` abaixo desse teto.

## Histórico

Os arquivos do primeiro teste (runbook, SQL, preflight do `.162` e perfis `fs02-*`) foram removidos
do repositório depois da campanha completa e continuam no histórico do git:

```bash
git log --oneline -- deploy/stfc-fs02
```
