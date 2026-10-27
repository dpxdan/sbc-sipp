# Instalador local por papel (`install/flux-host.sh`)

O `flux-host.sh` roda **no próprio servidor Debian 12**, como root, e prepara só o que
aquele servidor faz no teste. Não há orquestrador por SSH: o repositório é clonado em cada
servidor (ou copiado) e o comando é executado lá.

| Papel | Servidor (STFC) | O que é |
|---|---|---|
| `freeswitch` | `sbc-stfc-1`, `sbc-stfc-02` | FreeSWITCH 1.11.3 com a stack Flux (xml_curl no PHP-FPM 7.3, dialplan Lua, ODBC) |
| `opensips` | `sbc-stfc-1` | OpenSIPS 3.6 (`mid_registrar` + `load_balancer`) |
| `mysql` | `banco-master-sbc-stfc`, `banco-slave-stfc` | Percona XtraDB Cluster 8.4.10 + keepalived (VIP) |
| `web` | `sbc-stfc-interfaceweb` | nginx 1.22.1 + PHP-FPM 7.3 |
| `gen` | servidor de testes | SIPp, wrk, sysbench, limites de rede e o `loadtest.conf` |
| `zabbix-agent` | servidor de testes (só `prepare`/`check`) | zabbix-agentd e o wrapper do disparo de perfis pelo Zabbix ([`docs/configuracao/zabbix.md`](../docs/configuracao/zabbix.md)) |

Vários papéis no mesmo servidor: `flux-host.sh lab freeswitch opensips`.

Há dois modos, com riscos muito diferentes:

| Modo | Para | O que faz |
|---|---|---|
| `lab` | Servidores de laboratório recém-instalados | Instalação completa (pacotes, configuração, systemd), com os mesmos papéis do `lab/vm/vmlab.sh` (`lab/vm/roles`) |
| `prepare` | Servidores existentes, como os do STFC | Só os pré-requisitos do flux-loadtest. Nunca instala, atualiza, reconfigura nem reinicia FreeSWITCH, OpenSIPS ou MySQL |

`check` (somente leitura) serve aos dois.

## Modo `lab`

### 1. Inventário e senhas (servidor de testes)

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

```bash
/opt/flux-loadtest/install/flux-host.sh init
```

A primeira execução cria `/etc/flux-lab/host.conf` a partir de `install/host.conf.example`
(mesmas chaves do `lab/vm/vmlab.conf`). Ajuste `GEN_IP`, `HOST_*`, `DB_VIP`, `NET_PATTERN`
e `FLUX_GIT_URL` e rode o `init` de novo: ele gera `STATE_DIR/secrets.env` (0600).

Copie os dois arquivos para os outros 5 servidores, **nos mesmos caminhos e com 0600**. Em
cada SBC, grave também o token da SignalWire em `SIGNALWIRE_TOKEN_FILE` (0600; só é lido na
primeira instalação do FreeSWITCH).

### 2. Instalação, nesta ordem

O servidor é identificado pelos IPs locais (ou por `--as sbc1|sbc2|db1|db2|web|gen`).

| # | Servidor | Comando |
|---|---|---|
| 1 | `banco-master-sbc-stfc` | `flux-host.sh lab mysql` (bootstrap do cluster) |
| 2 | `banco-slave-stfc` | `flux-host.sh lab mysql` (entra por SST) |
| 3 | `banco-master-sbc-stfc` | `flux-host.sh lab mysql` (com o nó 2 Synced, sai do `mysql@bootstrap`) |
| 4 | `banco-master-sbc-stfc` | `flux-host.sh mysql-schema` (schema do Flux, ramais, DIDs DIRECT-IP) |
| 5 | `sbc-stfc-interfaceweb` | `flux-host.sh lab web` |
| 6 | `sbc-stfc-02` | `flux-host.sh lab freeswitch` |
| 7 | `sbc-stfc-1` | `flux-host.sh lab freeswitch opensips` (o OpenSIPS sobe depois do FS) |
| 8 | servidor de testes | `flux-host.sh lab gen`, `flux-host.sh keys`, `flux-host.sh smoke` |
| 9 | servidor de testes | `flux-host.sh zabbix` (opcional, Zabbix existente) |

Todos os passos são idempotentes. Saída de cada papel em `/var/log/flux-host/<papel>.log`.
`freeswitch` e `mysql-schema` clonam o fork do Flux em `FLUX_SRC_DIR` (instalam o `git` se
faltar); repositório privado exige chave de deploy ou credencial do git em cada servidor.

Na primeira execução do `mysql`, o datadir do nó é recriado; o papel recusa se já existir o
schema `flux`. **Não use o modo `lab` em servidores com dados.**

Teste de carga, depois da instalação:

```bash
/opt/flux-loadtest/flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip -r 10 -H 20 -w 120 --label host-cps10
```

## Modo `prepare` (servidores STFC)

Não usa `host.conf`. Em cada servidor, só os papéis que ele tem:

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch opensips --dry-run
```

| Papel | Alteração | Validação |
|---|---|---|
| todos | usuário `loadtest` sem senha (a chave entra pelo `keys setup --via admin`); aviso se o NTP não estiver sincronizado | — |
| `freeswitch`, `opensips` | `/etc/sudoers.d/flux-loadtest` com os caminhos reais de `fs_cli`/`opensips-cli` (soma aos que já estão no arquivo) | `visudo -cf` antes de gravar |
| `mysql` | `/etc/mysql/flux-loadtest.cnf` (0600, dono `loadtest`) com a credencial do `flux_monitor`; com `--create-db-user`, `CREATE USER IF NOT EXISTS flux_monitor@localhost` (PROCESS, REPLICATION CLIENT) | login do `loadtest` no `check` |
| `web` | sem `--apply-status`, só informa. Com `--apply-status`: `server` próprio em `127.0.0.1:80` (`/etc/nginx/conf.d/flux-loadtest-status.conf`) com `/nginx_status` e `/fpm-status`, e `pm.status_path` num arquivo à parte do pool (`zz-flux-loadtest.conf`) | `nginx -t`, `php-fpm7.3 -t`; reload (graceful) |
| `gen` | papel `gen` do laboratório (pacotes, sysctl, limites) no servidor de testes | — |
| `zabbix-agent` | servidor de testes: `zabbix-agent` 7.2 (se faltar, com `--zabbix-server`), `/usr/local/sbin/flux-loadtest-zbx`, sudoers do usuário `zabbix`, include com `AllowKey` por perfil, `Server=` passivo; restart só do agent | `visudo -cf`, `zabbix_agentd -T` |

Fluxo de cada execução:

1. **Plano:** mostra o diff de cada arquivo (conteúdo com senha omitido) e os comandos. Nada é alterado.
2. **Confirmação:** digitar `SIM` (ou `-y`). Com `--dry-run`, para aqui.
3. **Aplicação:** backup em `/var/backups/flux-loadtest/<data>/`, gravação e validação. Se a validação falhar, o arquivo anterior volta.

Banco (PXC): a senha do `flux_monitor` vem de um arquivo 0600 (alfanumérica, 12+ caracteres),
**igual nos dois nós**. O `CREATE USER` é replicado: use `--create-db-user` em um nó só.

```bash
install -m 0600 /dev/null /root/flux_monitor.pass
```

```bash
read -r -s -p "Senha: " p && printf '%s\n' "$p" > /root/flux_monitor.pass && unset p
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare mysql --monitor-pass-file /root/flux_monitor.pass --create-db-user
```

No outro nó, sem `--create-db-user`. Um `flux_monitor` que já existe não tem a senha alterada:
se o `check` falhar no login, a senha do arquivo não é a do usuário.

Web: o `server` em `127.0.0.1:80` recebe todo o tráfego local para `127.0.0.1:80`. Se algo
no servidor depende desse endereço para chegar à aplicação, não use `--apply-status`. Com mais
de um pool no PHP-FPM, o `fpm-status` fica de fora (configure à mão).

Depois do `prepare`, continuam valendo: origem SIP autorizada no OpenSIPS
([`docs/instalacao/servidores.md`](../docs/instalacao/servidores.md)), DIDs de teste
([`docs/instalacao/massa-dids.md`](../docs/instalacao/massa-dids.md)) e `keys setup`
([`docs/configuracao/chaves-ssh.md`](../docs/configuracao/chaves-ssh.md)).

## `check`

```bash
/opt/flux-loadtest/install/flux-host.sh check freeswitch opensips
```

Serviço ativo, `fs_cli`/`opensips-cli` respondendo, sudoers do `loadtest`, estado WSREP,
login da credencial de coleta, endpoints de status e ferramentas do gerador. Código de saída 1
se algo falhar.

## Diferenças em relação ao `vmlab.sh`

| Item | `vmlab.sh` | `flux-host.sh lab` |
|---|---|---|
| Onde roda | Servidor de testes, por SSH nas 5 VMs | Em cada servidor |
| Ordem do cluster | Automática | Manual (tabela acima); o nó 1 volta a membro comum na segunda execução |
| Clone do Flux | No servidor de testes, enviado por `tar` | Em cada SBC e no nó 1 (`FLUX_SRC_DIR`) |
| Senhas | `STATE_DIR` no servidor de testes, enviadas no `role.env` | `secrets.env` copiado para cada servidor |
| Papéis | `lab/vm/roles` | Os mesmos; inventário em `lab/lib/inventory.sh` (comum aos dois) |
