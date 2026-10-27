# Preparação dos servidores

Faça uma vez por ambiente, com revisão da equipe de infraestrutura. Nos servidores existentes
(STFC), o instalador `install/flux-host.sh prepare` faz só os pré-requisitos do flux-loadtest e
**nunca** instala, atualiza, reconfigura ou reinicia FreeSWITCH, OpenSIPS ou MySQL.

## O que cada servidor precisa

| Servidor | O que precisa |
|---|---|
| Todos | Usuário SSH com chave (a ação `keys` instala) e `bash` |
| FreeSWITCH | `fs_cli` executável pelo usuário SSH (direto ou com `sudo -n`) |
| OpenSIPS | `opensips-cli` executável pelo usuário SSH; IP da VM na tabela `address` |
| MySQL | Usuário somente leitura para a coleta (`PROCESS`, `REPLICATION CLIENT`) |
| Web | `stub_status` do nginx e status do PHP-FPM liberados para 127.0.0.1 (opcional) |

## `flux-host.sh prepare`

Em cada servidor, como root, só com os papéis que ele tem:

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch opensips --dry-run
```

| Papel | Alteração | Validação |
|---|---|---|
| todos | Usuário `loadtest` sem senha (a chave entra pelo `keys setup`); aviso se o NTP não estiver sincronizado | — |
| `freeswitch`, `opensips` | `/etc/sudoers.d/flux-loadtest` com os caminhos reais de `fs_cli` e `opensips-cli` | `visudo -cf` antes de gravar |
| `mysql` | `/etc/mysql/flux-loadtest.cnf` (0600, dono `loadtest`) com a credencial do `flux_monitor`; com `--create-db-user`, cria o usuário | Login no `check` |
| `web` | Sem `--apply-status`, só informa. Com ele: `server` em `127.0.0.1:80` com `/nginx_status` e `/fpm-status` | `nginx -t`, `php-fpm7.3 -t`, reload |
| `gen` | Pacotes, sysctl e limites do gerador | — |
| `zabbix-agent` | Wrapper do disparo de perfis pelo Zabbix (veja [Zabbix](../configuracao/zabbix.md)) | `zabbix_agentd -t agent.ping` |

Fluxo de cada execução:

1. **Plano:** mostra o diff de cada arquivo (senhas omitidas) e os comandos.
2. **Confirmação:** digitar `SIM` (ou `-y`). Com `--dry-run`, para aqui.
3. **Aplicação:** backup em `/var/backups/flux-loadtest/<data>/`, gravação e validação. Se a
   validação falhar, o arquivo anterior volta.

!!! tip "Não filtre a saída"
    O `prepare` sem `--dry-run` pede `SIM`. Um `| grep` no comando esconde a pergunta e o comando
    parece travado.

Conferência (somente leitura; código 1 se algo falhar):

```bash
/opt/flux-loadtest/install/flux-host.sh check freeswitch opensips
```

### No STFC

| Servidor | Comando |
|---|---|
| `.163` (FS + OpenSIPS) | `flux-host.sh prepare freeswitch opensips` |
| `.162` (FS) | `flux-host.sh prepare freeswitch` |
| `.161` (banco, nó 1) | `flux-host.sh prepare mysql --monitor-pass-file /root/flux_monitor.pass --create-db-user` |
| `.164` (banco, nó 2) | `flux-host.sh prepare mysql --monitor-pass-file /root/flux_monitor.pass` |
| `.165` (gerador) | `flux-host.sh prepare gen` |

## sudoers (usuário SSH sem root)

O `prepare` grava o arquivo. Manualmente, o conteúdo equivalente é:

```
loadtest ALL=(root) NOPASSWD: /usr/bin/fs_cli, /usr/bin/opensips-cli
```

Valide com `visudo -cf /etc/sudoers.d/flux-loadtest` antes de usar. No `loadtest.conf`,
`FS_CLI_CMD="sudo -n fs_cli -x"` e `OPENSIPS_MI_CMD="sudo -n opensips-cli -x mi"`.

## Senha do event socket (`fs_cli`)

O preflight e o `fs-limites.sh` usam o `fs_cli` como root. Se ele não responder, crie o
`/root/.fs_cli_conf` (o formato precisa da seção `[default]`):

```bash
install -m 0600 /dev/null /root/.fs_cli_conf
```

```bash
read -r -s -p "Senha do event socket: " p && printf '[default]\npassword => %s\n' "$p" > /root/.fs_cli_conf && unset p
```

Se o `listen-ip` do event socket não for `127.0.0.1` ou `::`, inclua `host => <listen-ip>`.

Para a coleta pela VM, a senha fica em `FS_CLI_PASSWORD_FILE` ou é digitada com `--fs-password`
(veja [Segurança](../referencia/seguranca.md)).

## MySQL

No Percona XtraDB Cluster, o `CREATE USER` é replicado: crie os usuários em um nó só.

Senha do `flux_monitor`, igual nos dois nós (alfanumérica, 12 caracteres ou mais):

```bash
install -m 0600 /dev/null /root/flux_monitor.pass
```

```bash
read -r -s -p "Senha do flux_monitor: " p && printf '%s\n' "$p" > /root/flux_monitor.pass && unset p
```

Equivalente manual do usuário de coleta:

```sql
CREATE USER 'flux_monitor'@'localhost' IDENTIFIED BY '...';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'flux_monitor'@'localhost';
```

Para a latência média das instruções (`db_stmt_avg_ms`), o usuário também precisa ler o
`performance_schema`. Sem isso, a coluna fica vazia e o gatilho do Zabbix não dispara:

```sql
GRANT SELECT ON performance_schema.* TO 'flux_monitor'@'localhost';
```

Só para `--tests mysql`, um usuário restrito ao schema de teste, a partir da VM (que precisa estar
na rede interna):

```sql
CREATE USER 'flux_bench'@'IP_DA_VM' IDENTIFIED BY '...';
GRANT ALL ON loadtest.* TO 'flux_bench'@'IP_DA_VM';
```

## Status do nginx e do PHP-FPM (opcional)

Sem eles, as colunas `ngx_*` e `fpm_*` ficam vazias, mas o teste roda.

```
location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }
```

No pool do PHP-FPM: `pm.status_path = /fpm-status`, com um `location` equivalente liberado só
para 127.0.0.1. O `prepare web --apply-status` faz os dois.

!!! warning "Antes do `--apply-status`"
    O `server` em `127.0.0.1:80` recebe todo o tráfego local para esse endereço. Se algo no
    servidor depende dele para chegar à aplicação, configure à mão. Com mais de um pool no
    PHP-FPM, o `fpm-status` também precisa ser configurado à mão.

## Origem SIP autorizada

| Destino | O que liberar |
|---|---|
| OpenSIPS (5060) | IP da VM na tabela `address`, grupo de operadoras (`FLUX_GRP_CARRIERS` = 10), seguido de `opensips-cli -x mi address_reload` |
| FreeSWITCH direto (5070) | IP da VM na ACL de entrada do profile; veja [FreeSWITCH direto](../execucao/fs-direto.md) |
| Event Guard / fail2ban | IP da VM na whitelist (Event Guard pela interface; `ignoreip` no jail do SIP) |
| Firewall dos SBC | Entrada UDP vinda da VM: SIP e a faixa RTP do `switch.conf` (padrão 16384-32768) |

Atrás de NAT, libere o IP **público** da VM, não o privado.

No STFC, o `.165` entra como operadora pelo SQL do runbook:

```bash
mysql flux < /opt/flux-loadtest/deploy/stfc-completo/sql/10-opensips-address-add.sql
```

No `.163` (recarrega só a tabela `address`, sem restart):

```bash
opensips-cli -x mi address_reload
```

```bash
opensips-cli -x mi address_dump | grep -B2 -A6 200.159.177.165
```

### Firewall dos SBC (regra temporária)

Antes, confira se o iptables é o `nf_tables` e se há tabelas nativas do nftables (somente
leitura):

```bash
iptables -V
```

```bash
nft list tables
```

Se só houver as tabelas do iptables (`ip filter`, `ip6 filter`), uma regra temporária, não
persistente, marcada para a remoção:

```bash
iptables -I INPUT -s 200.159.177.165/32 -p udp -m comment --comment flux-loadtest -j ACCEPT
```

Se houver uma tabela nativa (ex.: `inet filter`) com `policy drop`, a regra precisa existir nela
também. Revise o `nft list ruleset` com a infraestrutura antes de alterar.
