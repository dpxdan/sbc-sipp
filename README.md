# flux-loadtest — teste de carga do FluxSBC (WEB-1437)

Ferramenta de teste de carga executada a partir de uma **VM separada** (VM de teste),
que atua nos servidores do FluxSBC por SSH. Ela gera carga SIP (INVITE para DIDs),
carga HTTP (nginx + PHP-FPM) e, opcionalmente, carga no MySQL, enquanto monitora
CPU, memória, rede, disco e métricas de cada serviço em todos os servidores. O
resultado é um relatório `.txt` por execução, com os dados brutos ao lado.

> Os servidores do ambiente de teste (STFC) estão na seção 1.1, e o
> `loadtest.conf.example` já vem preenchido para eles. Os demais IPs (por exemplo,
> o IP público da VM de teste, `203.0.113.50`) e os DIDs `5500000000001...` são
> **exemplos**: substitua pelos valores reais.

## Sumário

1. [Visão geral](#1-visão-geral)
2. [Arquivos](#2-arquivos)
3. [Requisitos](#3-requisitos)
4. [Instalação na VM de teste](#4-instalação-na-vm-de-teste)
5. [Configuração](#5-configuração)
6. [Preparação dos servidores](#6-preparação-dos-servidores)
7. [Comandos](#7-comandos)
8. [Exemplos de testes](#8-exemplos-de-testes)
9. [Como o `run` funciona por dentro](#9-como-o-run-funciona-por-dentro)
10. [Coletor de métricas](#10-coletor-de-métricas)
11. [Relatório e arquivos de saída](#11-relatório-e-arquivos-de-saída)
12. [Limites de segurança (guard)](#12-limites-de-segurança-guard)
13. [Segurança de credenciais](#13-segurança-de-credenciais)
14. [Mídia](#14-mídia)
15. [Dimensionamento da VM de teste](#15-dimensionamento-da-vm-de-teste)
16. [Referência das funções](#16-referência-das-funções)
17. [Solução de problemas](#17-solução-de-problemas)
18. [Limitações](#18-limitações)
19. [Zabbix](#19-zabbix)

---

## 1. Visão geral

```
VM de teste --INVITE:5060--> OpenSIPS (sbc-stfc-1) --lb_start--> FS1 :5070 (sbc-stfc-1)
     |                                                      \--> FS2 :5070 (sbc-stfc-02)
     |<--INVITE:5090 + RTP do FS (DIDs DIRECT-IP, atendedor)         |
     |--wrk--> nginx -> PHP-FPM 7.3 (sbc-stfc-interfaceweb)          v
     |                         \------------------------> VIP 172.17.4.100 (keepalived)
     |--sysbench (opcional, rede interna) --------------->   Percona XtraDB Cluster
     |                                                       banco-master <-wsrep-> banco-slave
     +--ssh (coletor /proc) --> todos os servidores
```

- **SIP:** o SIPp envia INVITE para DIDs de uma conta de teste. As chamadas entram
  no OpenSIPS como operadora e seguem pelo `load_balancer` até os FreeSWITCH. Os DIDs
  são DIRECT-IP (`call_type = 2`) e apontam para a própria VM: um segundo SIPp
  (atendedor, `UAS_PORT`) recebe o bridge do FS e atende, com mídia nos dois sentidos
  (seção 6.6). Também é possível apontar direto para um FreeSWITCH (seção 8.4).
- **Web:** o `wrk` mede um arquivo estático (nginx puro) e uma página PHP (nginx +
  PHP-FPM + sessão no MySQL).
- **MySQL:** sempre coletado de forma passiva; carga ativa com `sysbench`
  opcional, em schema isolado.
- **Monitoramento:** um coletor somente leitura roda em cada servidor (e na própria
  VM) durante todo o teste. Nada é instalado nem gravado nos servidores.
- **Produção:** confirmação obrigatória, limites de segurança que param a carga de
  forma suave, e `--dry-run` para revisar o plano antes.

### 1.1 Ambiente STFC

Todos os servidores rodam **Debian 12**.

| Servidor | IP público | IP interno | Função | Versões e portas |
|---|---|---|---|---|
| `sbc-stfc-1` | 200.159.177.163 | 172.17.4.163 | OpenSIPS + FreeSWITCH 1 | OpenSIPS 3.6.8 (SIP 5060); FreeSWITCH 1.11.3 (SIP 5070) |
| `sbc-stfc-02` | 200.159.177.162 | 172.17.4.162 | FreeSWITCH 2 | FreeSWITCH 1.11.3 (SIP 5070) |
| `banco-master-sbc-stfc` | 200.159.177.161 | 172.17.4.161 | Banco (nó 1) | MySQL 8.4.10-10.1 Percona XtraDB Cluster, WSREP 26.1.4.3 |
| `banco-slave-stfc` | 200.159.177.164 | 172.17.4.164 | Banco (nó 2) | MySQL 8.4.10-10.1 Percona XtraDB Cluster, WSREP 26.1.4.3 |
| `sbc-stfc-interfaceweb` | 200.159.177.165 | 172.17.4.165 | Interface web | nginx 1.22.1; PHP-FPM 7.3.33 |
| VIP do banco (keepalived) | — | 172.17.4.100 | Endereço usado pelos servidores para acessar o MySQL | — |

Consequências para o teste:

- **OpenSIPS e FS1 no mesmo servidor.** O `sbc-stfc-1` aparece duas vezes na
  configuração (`OPENSIPS_HOST` e `FS_HOSTS`). São dois coletores no mesmo servidor:
  as métricas de sistema (CPU, memória, rede, disco) se repetem em `opensips` e `fs1`, e
  as de serviço são separadas (OpenSIPS em um, FreeSWITCH no outro). A CPU desse
  servidor é a soma dos dois serviços.
- **Banco em Percona XtraDB Cluster.** "Master" e "slave" são os dois nós de um cluster
  Galera com replicação síncrona (WSREP), não uma réplica assíncrona: o
  `SHOW REPLICA STATUS` fica vazio e o que importa é o estado do cluster (seções 10 e 12).
  Com só dois nós e sem árbitro (`garbd`), a queda abrupta de um nó tira o quórum do outro.
- **VIP interno.** O VIP 172.17.4.100 só é alcançável de dentro da rede
  172.17.4.0/24. A coleta no banco funciona de qualquer lugar (roda no próprio servidor),
  mas `--tests mysql` (sysbench) exige uma VM de teste na rede interna.
- **VM de teste fora da rede interna** (por exemplo, no Parallels): usa os IPs públicos,
  sai por NAT e precisa ter o IP público liberado (seção 6.3).

## 2. Arquivos

| Arquivo | Função |
|---|---|
| `flux-loadtest.sh` | Orquestrador. Ações: `keys`, `check`, `smoke`, `run`, `report`, `zabbix` |
| `lib/collector.sh` | Coletor de métricas enviado por SSH (`bash -s`); lê `/proc` e comandos de status |
| `lib/flux_zabbix.py` | Envio ao Zabbix por trapper (ao vivo e importação) e provisionamento dos hosts pela API (seção 19) |
| `zabbix/flux-loadtest-templates.yaml` | Templates no formato do Zabbix 7.2 (produção: 7.2.3; gerado, não editar à mão) |
| `zabbix/gen_templates.py` | Gerador dos templates a partir das colunas do coletor |
| `scenarios/uac-did.xml.in` | Modelo do cenário SIPp: INVITE -> 200 -> ACK -> RTP opcional -> BYE |
| `scenarios/uas-answer.xml.in` | Modelo do atendedor (UAS) dos DIDs DIRECT-IP: INVITE -> 180/200 -> ACK -> RTP opcional -> BYE |
| `loadtest.conf.example` | Configuração comentada (copiar para `loadtest.conf`) |
| `dids.txt.example` | Formato do arquivo de DIDs e consulta para exportá-los do banco |
| `lab/` | Laboratório STFC em Docker para validar o script sem tocar na produção: banco (Percona XtraDB Cluster 8.4.10 + keepalived), web (nginx 1.22.1 + PHP-FPM 7.3.33), OpenSIPS 3.6 e FreeSWITCH 1.11.3 reais com os scripts do Flux, Zabbix 7.2.3, acesso pelo macOS e registro de SIP devices (veja `lab/README.md`) |
| `bin/flux-loadtest-zbx` | Disparo de perfis pelo Zabbix: chamado pelo zabbix-agentd do servidor de testes (seção 19.6) |
| `profiles/*.conf.example` | Perfis de teste para o disparo pelo Zabbix |
| `lab/vm/` | O mesmo laboratório em 6 VMs Debian 12, sem Docker: o `vmlab.sh` roda no servidor de testes e configura as outras 5 VMs por SSH, com systemd (veja `lab/vm/README.md`) |
| `install/` | Instalador local por papel (`freeswitch`, `opensips`, `mysql`, `web`, `gen`): `flux-host.sh lab` instala o laboratório no próprio servidor; `flux-host.sh prepare` só prepara servidores existentes (STFC) para o teste (veja `install/README.md`) |

## 3. Requisitos

### VM de teste

| Item | Requisito |
|---|---|
| Sistema | Debian 12 (bash 5, `/proc`, `ip`) |
| Pacotes | `sip-tester` (SIPp 3.6.1), `wrk`, `openssh-client`, `curl`, `python3` |
| Opcional | `sysbench` e `default-mysql-client` (só para `--tests mysql`) |
| Usuário | root, ou um usuário com escrita em `RESULTS_DIR` e `/etc/flux-loadtest` |
| Rede | SSH até todos os servidores; UDP até o destino SIP; HTTPS até o servidor web |
| Relógio | NTP/chrony ativo (os timestamps vêm de cada servidor) |

### Servidores

| Servidor | O que precisa |
|---|---|
| Todos | Usuário SSH com chave (a ação `keys` cuida disso) e `bash` |
| FreeSWITCH | `fs_cli` executável pelo usuário SSH (direto ou com `sudo -n`) |
| OpenSIPS | `opensips-cli` executável pelo usuário SSH; IP da VM na tabela `address` |
| MySQL | Usuário somente leitura para a coleta (`PROCESS`, `REPLICATION CLIENT`) |
| Web | `stub_status` do nginx e status do PHP-FPM liberados para 127.0.0.1 (opcional) |

## 4. Instalação na VM de teste

**1. Pacotes:**

```bash
apt install sip-tester wrk openssh-client curl python3
```

Só se for usar `--tests mysql`:

```bash
apt install sysbench default-mysql-client
```

**2. Copiar os arquivos** do repositório para a VM (a partir do diretório raiz deste
repositório, na máquina que tem o clone):

```bash
scp -r . usuario@VM_DE_TESTE:/tmp/loadtest
```

Na VM:

```bash
mkdir -p /opt/flux-loadtest && cp -r /tmp/loadtest/. /opt/flux-loadtest/
```

```bash
chmod +x /opt/flux-loadtest/flux-loadtest.sh /opt/flux-loadtest/lib/collector.sh /opt/flux-loadtest/lib/flux_zabbix.py
```

**3. Diretórios de configuração e resultados:**

```bash
install -d -m 0700 /etc/flux-loadtest
```

```bash
install -d -m 0750 /var/lib/flux-loadtest/results
```

**4. Configuração e lista de DIDs:**

```bash
cd /opt/flux-loadtest && cp loadtest.conf.example loadtest.conf
```

```bash
install -m 0644 dids.txt.example /etc/flux-loadtest/dids.txt
```

Edite `loadtest.conf` (seção 5) e troque os DIDs fictícios de
`/etc/flux-loadtest/dids.txt` pelos DIDs da conta de teste (seção 6.6).

**5. Conferir a ajuda:**

```bash
./flux-loadtest.sh --help
```

## 5. Configuração

O `loadtest.conf` fica ao lado do script (ou é indicado com `-c ARQUIVO`).

- Formato: `CHAVE=valor`, uma por linha, sem espaços ao redor do `=`.
- Aspas envolventes são removidas; comentários só em linhas próprias (`#`).
- O arquivo é lido como **dado**, nunca executado: chave desconhecida é recusada.
- Servidor não configurado (chave vazia) fica fora do teste. Para testar só um
  FreeSWITCH, preencha apenas `FS_HOSTS`.

### 5.1 SSH

| Chave | Padrão | Descrição |
|---|---|---|
| `SSH_USER` | — | Usuário nos servidores (obrigatório) |
| `SSH_KEY` | — | Chave privada da VM (caminho absoluto); criada por `keys create` |
| `SSH_PORT` | `22` | Porta SSH dos servidores |
| `SSH_OPTS` | `-o BatchMode=yes -o ConnectTimeout=5 ...` | Opções extras do `ssh` |
| `SSH_KNOWN_HOSTS` | vazio (`~/.ssh/known_hosts`) | `known_hosts` dedicado; preenchido por `keys trust` |
| `SSH_KEY_TYPE` | `ed25519` | `ed25519` ou `rsa` (4096 bits) |
| `SSH_KEY_COMMENT` | `flux-loadtest@<host>-<data>` | Comentário da chave |
| `SSH_KEY_FROM` | vazio (detecta pela rota) | `from=` do `authorized_keys`; obrigatório atrás de NAT |

### 5.2 Servidores

| Chave | Valor no STFC | Descrição |
|---|---|---|
| `OPENSIPS_HOST` | `200.159.177.163` | OpenSIPS (`sbc-stfc-1`) |
| `FS_HOSTS` | `"200.159.177.163 200.159.177.162"` | FreeSWITCH, separados por espaço (viram `fs1`, `fs2`) |
| `DB_HOSTS` | `"200.159.177.161 200.159.177.164"` | Nós do cluster (viram `db1`, `db2`) |
| `WEB_HOST` | `200.159.177.165` | Servidor web (nginx + PHP-FPM) |

Numa VM de teste dentro da rede interna, use os IPs 172.17.4.x.

### 5.3 SIP

| Chave | Padrão | Descrição |
|---|---|---|
| `SIP_TARGET` | — | Destino das chamadas, `IP:porta`. STFC: OpenSIPS `200.159.177.163:5060`; FS direto `200.159.177.163:5070` ou `200.159.177.162:5070` |
| `SIP_LOCAL_IP` | vazio (detecta pela rota) | IP de origem do SIPp na VM |
| `SIP_LOCAL_PORT` | `5060` | Porta de origem do SIPp |
| `DID_FILE` | — | Arquivo de DIDs (um por linha; aceita `#` e linhas vazias) |
| `CALLER_ID` | — | Número de A das chamadas (facilita filtrar CDRs) |
| `RTP_PORT_BASE` | `20000` | Porta base de RTP do SIPp |
| `SIP_RECV_TIMEOUT_MS` | `60000` | Espera máxima pelo 200 OK; depois a chamada conta como falha |
| `UAS_PORT` | vazio | Porta UDP do atendedor (SIPp UAS) na VM. Os DIDs ficam como DIRECT-IP com `extensions = <IP da VM visto pelos FS>:UAS_PORT` (seção 6.6). Vazio = sem atendedor |
| `UAS_RTP_PORT_BASE` | `40000` | Porta base de RTP do atendedor (diferente de `RTP_PORT_BASE`) |

### 5.4 FreeSWITCH

| Chave | Padrão | Descrição |
|---|---|---|
| `FS_CLI_CMD` | `fs_cli -x` | Comando no servidor (ex.: `sudo -n fs_cli -x`, ou com `-H`/`-P`) |
| `FS_CLI_PASSWORD_FILE` | vazio | Arquivo 0600 na VM com a senha do event socket (seção 13) |
| `FS_DISK_PATH` | `/var/lib/freeswitch` | Partição vigiada pelo limite de disco (gravações, logs, caixa postal) |
| `VM_BOXES` | vazio | Caixas postais de teste (`ramal@dominio`) contadas antes/depois |
| `VM_GREETING_SECONDS` | `8` | Duração da saudação (só para a estimativa de disco do plano) |
| `VM_BYTES_PER_SECOND` | `16000` | Bytes/s gravados por chamada (WAV 8 kHz 16 bit) |

### 5.5 OpenSIPS, MySQL e Web (coleta)

| Chave | Padrão | Descrição |
|---|---|---|
| `OPENSIPS_MI_CMD` | `opensips-cli -x mi` | Comando MI no servidor OpenSIPS |
| `MYSQL_CLI_CMD` | `mysql` | Cliente no servidor de banco (ex.: `mysql --defaults-extra-file=...`) |
| `MYSQL_DISK_PATH` | `/var/lib/mysql` | Partição de dados do MySQL |
| `FLUX_DB_NAME` | `flux` | Schema do Flux; o sysbench se recusa a usar este nome |
| `DB_VIP` | vazio | VIP do keepalived (STFC: `172.17.4.100`); o coletor marca em qual nó ele está |
| `NGINX_STATUS_URL` | vazio | URL do `stub_status`, lida no próprio servidor web |
| `FPM_STATUS_URL` | vazio | URL do status do PHP-FPM (`?json`), lida no servidor web |
| `WEB_PROCS` | `nginx,php-fpm` | Processos somados no servidor web |

### 5.6 Web (carga com wrk)

| Chave | Padrão | Descrição |
|---|---|---|
| `WEB_BASE_URL` | — | URL base, a partir da VM (obrigatória com `--tests web`). STFC: `https://200.159.177.165` |
| `WEB_STATIC_PATH` | `/assets/images/addon_icon.png` | Alvo estático (mede só o nginx) |
| `WEB_PHP_PATH` | `/` | Alvo PHP (nginx + PHP-FPM + sessão) |
| `WEB_EXTRA_PATH` | vazio | Terceiro alvo opcional |
| `WEB_TLS_INSECURE` | `1` | Aceita certificado autoassinado no `curl` |
| `WEB_REUSE_SESSION` | `1` | Reutiliza um único cookie de sessão (seção 9.4) |
| `WEB_SESSION_COOKIE` | `ci_session` | Nome do cookie de sessão do CodeIgniter |

### 5.7 MySQL (carga com sysbench)

| Chave | Padrão | Descrição |
|---|---|---|
| `MYSQL_BENCH_HOST` / `_PORT` | — / `3306` | VIP, a partir da VM. STFC: `172.17.4.100` (só na rede interna) |
| `MYSQL_BENCH_USER` | — | Usuário com `ALL` só no schema de teste |
| `MYSQL_BENCH_PASSWORD_FILE` | — | Arquivo com a senha (0600) |
| `MYSQL_BENCH_DB` | `loadtest` | Schema isolado (nunca o do Flux) |
| `MYSQL_BENCH_TABLES` / `_TABLE_SIZE` | `4` / `100000` | Tamanho da massa do sysbench |
| `MYSQL_BENCH_THREADS` | `8` | Conexões simultâneas |
| `MYSQL_BENCH_EXTRA_ARGS` | vazio | Ex.: `--mysql-ssl=on` |

### 5.8 Limites de segurança e coleta

| Chave | Padrão | Descrição |
|---|---|---|
| `GUARD_MAX_CPU_PCT` | `85` | CPU total de um servidor |
| `GUARD_MAX_GEN_CPU_PCT` | `90` | CPU da própria VM de teste |
| `GUARD_MAX_MEM_PCT` | `90` | Memória usada |
| `GUARD_MIN_DISK_FREE_PCT` | `15` | Disco livre mínimo (`FS_DISK_PATH`, `MYSQL_DISK_PATH`, `/`) |
| `GUARD_MAX_FAIL_PCT` | `5` | Falha SIP no período (mínimo de 10 chamadas) |
| `GUARD_MAX_REPL_LAG` | `30` | Atraso de replicação assíncrona (s); réplica parada também dispara. Não se aplica ao Percona XtraDB Cluster |
| `GUARD_MAX_WSREP_FC_PCT` | `10` | Percona XtraDB Cluster: fração máxima do intervalo com a replicação pausada por flow control (%; `0` desliga) |
| `GUARD_MIN_WSREP_CLUSTER_SIZE` | `0` (STFC: `2`) | Tamanho mínimo do cluster (`0` desliga) |
| `GUARD_MAX_CORE_PCT` | `0` (desligado) | Núcleo mais carregado (o FS tem thread que ocupa ~95% de um núcleo) |
| `GUARD_HITS` | `3` | Amostras seguidas acima do limite para interromper |
| `SAMPLE_INTERVAL` | `5` | Intervalo de coleta (s) |
| `BASELINE_SECONDS` / `COOLDOWN_SECONDS` | `60` / `60` | Fases sem carga antes e depois |
| `RESULTS_DIR` | `/var/lib/flux-loadtest/results` | Onde os resultados são gravados |

### 5.9 Zabbix (opcional)

| Chave | Padrão | Descrição |
|---|---|---|
| `ZABBIX_SERVER` | vazio (sem Zabbix) | Servidor ou proxy Zabbix que recebe os valores por trapper |
| `ZABBIX_PORT` | `10051` | Porta do trapper |
| `ZABBIX_HOST_PREFIX` | `flt-` | Prefixo dos hosts no Zabbix (`flt-fs1`, `flt-run`...) |
| `ZABBIX_LIVE` | `1` | `1` envia durante o `run`; `0` só pela importação (`zabbix send`) |
| `ZABBIX_API_URL` | vazio | `https://.../api_jsonrpc.php`; usada só por `zabbix setup` e `zabbix check` |
| `ZABBIX_API_TOKEN_FILE` | vazio | Arquivo 0600 com o token de API (64 hexadecimais) |
| `ZABBIX_TLS_INSECURE` | `0` | `1` aceita certificado autoassinado na API |

## 6. Preparação dos servidores

Faça uma vez por ambiente, revisado pela equipe de infraestrutura.

O `install/flux-host.sh prepare <papel>`, executado em cada servidor, faz as seções 6.2, 6.4
(credencial de coleta) e 6.5 com plano, confirmação e backup (veja `install/README.md`).

### 6.1 Chaves SSH

```bash
./flux-loadtest.sh keys setup --via admin --write-config
```

Cria a chave, grava as chaves de host, instala a chave restrita à VM e testa
(detalhes na seção 7.1). Atrás de NAT (por exemplo, VM no Parallels), informe o IP
público que os servidores enxergam:

```bash
curl -s https://ifconfig.me
```

```bash
./flux-loadtest.sh keys setup --from 203.0.113.50 --via admin --write-config
```

### 6.2 sudoers (se o usuário SSH não for root)

Exemplo de arquivo `/etc/sudoers.d/flux-loadtest` nos servidores, revisado com
`visudo -cf`:

```
loadtest ALL=(root) NOPASSWD: /usr/bin/fs_cli, /usr/bin/opensips-cli
```

### 6.3 Origem SIP autorizada

| Destino | O que liberar |
|---|---|
| OpenSIPS (`sbc-stfc-1`, 5060) | IP da VM na tabela `address`, grupo de operadoras (`FLUX_GRP_CARRIERS` = 10), seguido de `opensips-cli -x mi address_reload` |
| FreeSWITCH direto (5070 no `sbc-stfc-1` e no `sbc-stfc-02`) | IP da VM na ACL de entrada do profile. No FluxSBC a lista `domains` é gerada pelo `acl.lua` a partir de `system_components` e `domain.external_server` |
| Event Guard / fail2ban | IP da VM na whitelist, senão o volume de INVITEs pode bloquear a VM no meio do teste |
| Firewall da VM (atendedor) | Entrada vinda dos FS (`200.159.177.163` e `.162`): `UAS_PORT`/udp e o RTP a partir de `UAS_RTP_PORT_BASE` (2 portas por chamada simultânea) |

Atrás de NAT, libere o IP **público**, não o IP privado da VM.

### 6.4 MySQL

No STFC, crie os usuários uma vez: no Percona XtraDB Cluster, o `CREATE USER` é
replicado para os dois nós. Usuário somente leitura para a coleta, com a credencial em
arquivo 0600 **em cada servidor de banco**:

```
CREATE USER 'flux_monitor'@'localhost' IDENTIFIED BY '...';
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'flux_monitor'@'localhost';
```

Só para `--tests mysql`, um usuário restrito ao schema de teste, a partir da VM
(que precisa estar na rede interna para alcançar o VIP):

```
CREATE USER 'flux_bench'@'IP_DA_VM' IDENTIFIED BY '...';
GRANT ALL ON loadtest.* TO 'flux_bench'@'IP_DA_VM';
```

### 6.5 Status do nginx e do PHP-FPM (opcional)

O vhost atual (`web_interface/nginx/deb_flux.conf`) não expõe esses endereços.
Sem eles, as colunas `ngx_*` e `fpm_*` ficam vazias, mas o teste roda.

```
location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }
```

No pool do PHP-FPM: `pm.status_path = /fpm-status`, com um `location` equivalente
liberado só para 127.0.0.1.

### 6.6 DIDs de teste

Destino recomendado: **DID DIRECT-IP para o atendedor da VM de teste.** O dialplan Lua
(`custom_inbound_2` do `flux.xml.lua`) faz `bridge sofia/<perfil>/<DID>@<extensions>`;
com `extensions` = IP e porta da VM, o FS entrega a chamada ao SIPp atendedor
(`UAS_PORT`), que responde 200 OK com SDP e, com `--media rtp`, também transmite. A
chamada passa por OpenSIPS, `load_balancer`, consulta do DID no MySQL, billing e
bridge com mídia nos dois sentidos, como o tráfego real: os DIDs ativos do STFC
encaminham para PBXs por IP.

Por que não a caixa postal (validado no laboratório em 2026-10-14, detalhes em
`lab/README.md`, "Validação do SBC real"):

- DID para ramal **não registrado** termina em 480: o `flux-sipdevice-routing.lua`
  desliga a chamada antes do `leave_voicemail`, com os scripts do `sbc01` e do fork;
- DID para ramal **registrado** depende do nó: o REGISTER fica no FS escolhido pelo
  `dispatcher` (hash do usuário), mas o `load_balancer` distribui as chamadas de
  operadora entre os dois FS; no outro nó o resultado é `USER_NOT_REGISTERED`.

Cada DID do `DID_FILE` precisa:

- ser DIRECT-IP (`call_type = 2`) com `extensions = <IP da VM visto pelos FS>:<UAS_PORT>`
  (atrás de NAT, o IP público da VM);
- pertencer a uma conta de teste **sem tarifa** (cada chamada gera CDR e passa pelo
  billing), com `maxchannels` e crédito que não limitem o teste;
- usar uma faixa de numeração fictícia, que nenhuma operadora encaminhe.

Use pelo menos tantos DIDs quanto chamadas simultâneas.

> **Não use DIDs ativos de clientes.** Na base do STFC (outubro/2026), os 66,5 mil DIDs
> ativos encaminham para PBXs (por IP ou hostname) e números externos de 116 contas.
> Usá-los no teste geraria chamadas reais para os clientes.

Criação da massa (escrita no banco de produção: revisar e executar com o responsável
pelo ambiente). Antes, crie **um** DID DIRECT-IP pela interface na conta de teste e
compare as colunas com o `INSERT` abaixo (o schema pode ter colunas a mais). Em lotes
de 10 mil, para não gerar um writeset grande no Percona XtraDB Cluster:

```sql
SET SESSION cte_max_recursion_depth = 100000;
INSERT INTO dids (number, accountid, inc, extensions, status, call_type, leg_timeout, product_id,
  always, always_destination, user_busy, user_busy_destination, user_not_registered,
  user_not_registered_destination, no_answer, no_answer_destination, failover_extensions, last_modified_date)
WITH RECURSIVE seq (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 9999)
SELECT CONCAT('<PREFIXO_FICTICIO>', LPAD(n + <INICIO_DO_LOTE>, 8, '0')), <ID_CONTA_TESTE>, 60,
  '<IP_DA_VM>:5090', 0, 2, 30, 0, 0, '', 0, '', 0, '', 0, '', '', NOW()
FROM seq;
```

Exportar a lista para a VM (somente leitura):

```bash
mysql -N -B -e "SELECT number FROM dids WHERE accountid = <ID_CONTA_TESTE> AND status = 0 AND call_type = 2" flux > /etc/flux-loadtest/dids.txt
```

Remoção depois do teste (também em lotes):

```sql
DELETE FROM dids WHERE accountid = <ID_CONTA_TESTE> AND number LIKE '<PREFIXO_FICTICIO>%' LIMIT 10000;
```

Sem `UAS_PORT`, o `flux-loadtest` continua enviando para qualquer DID que o FS atenda
sozinho (por exemplo, caixa postal); o relatório só não terá a seção do atendedor.

## 7. Comandos

Formato geral:

```
./flux-loadtest.sh <ação> [opções] [-c ARQUIVO_DE_CONFIGURAÇÃO]
```

Códigos de saída:

| Código | Significado |
|---|---|
| `0` | Sucesso |
| `2` | Uso incorreto (opção inválida, valor fora do formato) |
| `3` | Configuração inválida ou arquivo ausente |
| `4` | Dependência ausente na VM de teste |
| `5` | Falha remota (SSH, smoke com falha, chave não instalada) |
| `6` | Execução interrompida (limite de segurança, Ctrl+C ou cancelamento) |

### 7.1 `keys` — chaves SSH

**Função:** criar a chave da VM, confiar nas chaves de host dos servidores,
instalar a chave pública no `authorized_keys` do `SSH_USER`, testar e revogar.

| Subcomando | O que faz |
|---|---|
| `create` | Gera `SSH_KEY` (`ed25519`, ou `rsa` de 4096 bits), permissão 0600, sem passphrase. Não sobrescreve uma chave existente: só mostra a impressão digital |
| `trust` | Lê as chaves de host com `ssh-keyscan`, mostra as impressões digitais e grava no `known_hosts` depois da confirmação |
| `deploy` | Instala a chave pública restrita à VM em cada servidor (pede senha) |
| `test` | Confirma o login por chave (sem senha) e se o `sudo -n` está disponível |
| `revoke` | Remove a chave do `authorized_keys` em todos os servidores (fim da campanha) |
| `setup` | `create` + `trust` + `deploy` + `test` |

| Opção | Descrição |
|---|---|
| `--key CAMINHO` | Sobrescreve `SSH_KEY` |
| `--type ed25519\|rsa` | Tipo da chave |
| `--comment TEXTO` | Comentário da chave |
| `--passphrase` | Pede passphrase (exige `ssh-agent` com a chave carregada no `run`) |
| `--from IPs` | `from=` do `authorized_keys` (IPs ou CIDR separados por vírgula) |
| `--via USUARIO` | Primeiro acesso com outro usuário + `sudo` (ex.: `admin`) |
| `--known-hosts ARQ` | `known_hosts` dedicado |
| `--write-config` | Grava `SSH_KEY` e `SSH_KNOWN_HOSTS` no `loadtest.conf` (backup `.bak`) |
| `-y` | Não pede confirmação |

Primeiro acesso do `deploy`:

- **Sem `--via`:** pede a senha do próprio `SSH_USER`, como o `ssh-copy-id`.
- **`--via admin`:** entra como `admin` (senha ou chave dele) e usa `sudo` para gravar
  no `authorized_keys` do `SSH_USER`, ajustando dono e permissões. É o caminho
  quando o login por senha do usuário ou do root está bloqueado
  (`PermitRootLogin prohibit-password` é o padrão do Debian).

Linha instalada em cada servidor:

```
from="203.0.113.50",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc ssh-ed25519 AAAA... flux-loadtest@vm-20261007
```

Se a chave vazar, ela não funciona de outra origem e não abre terminal nem túnel.
O script só executa comandos sem terminal, então as restrições não o afetam. Rodar
`deploy` de novo é seguro: a linha é mantida ou tem as restrições atualizadas.

### 7.2 `check` — validação somente leitura

**Função:** confirmar que tudo está pronto antes de qualquer carga. Não altera nada.

O que verifica:

- dependências na VM (`sipp`, `wrk`, `ssh`, `curl`, `python3`...), versão do SIPp,
  `ulimit -n`, IP de origem SIP e quantidade de DIDs válidos;
- SSH e diferença de relógio de cada servidor (avisa acima de 2 s);
- por papel: `fs_cli status` (inclui `max-sessions`, `sessions-per-second` e CPU
  ociosa) e disco no FS; `get_statistics` e `lb_list` no OpenSIPS; versão,
  `read_only`, estado do Percona XtraDB Cluster (tamanho, Primary, Synced) e em qual nó
  está o VIP no MySQL; processos e páginas de status no web;
- o nome de cada servidor (`uname -n`), mostrado também no relatório.

| Opção | Descrição |
|---|---|
| `--fs-password` | Pede a senha do `fs_cli` no terminal |

```bash
./flux-loadtest.sh check --fs-password
```

Se o FS não mostrar `is ready`, o `check` avisa: senha do event socket errada ou
usuário sem permissão para o `fs_cli`.

### 7.3 `smoke` — uma chamada de validação

**Função:** enviar uma única chamada (5 s de duração) e mostrar o resultado SIP.
Confirma que o destino aceita a origem e, com `UAS_PORT`, que o FS entrega a chamada
ao atendedor (o resultado mostra "Chamadas recebidas do FS"). Não usa SSH nem coleta
métricas.

| Opção | Descrição |
|---|---|
| `--did NÚMERO` | DID da chamada (padrão: o primeiro válido do `DID_FILE`) |
| `-M, --media rtp\|none` | Com ou sem RTP de origem (padrão `rtp`) |

```bash
./flux-loadtest.sh smoke --did 5500000000001 --media none
```

Saída esperada: `Concluidas com sucesso 1` e "smoke OK". "Encerradas pela VM (fim
do hold)" é o caminho normal: a VM desliga ao fim dos 5 s. Os arquivos do SIPp
ficam num diretório temporário mostrado no fim.

### 7.4 `run` — teste completo

**Função:** executar as fases de carga (seção 9), coletar métricas de todos os
servidores e gerar o relatório.

| Opção | Padrão | Descrição |
|---|---|---|
| `-t, --tests` | `sip,web` | Testes: qualquer combinação de `sip`, `web`, `mysql` |
| `-r, --cps` | — | CPS alvo (obrigatório com `sip`) |
| `--cps-start` | 10% do alvo | CPS inicial da rampa |
| `--ramp-step` | igual ao inicial | Incremento por degrau |
| `--ramp-interval` | `10` | Segundos entre degraus |
| `-w, --window` | `300` | Janela de envio de chamadas (s) |
| `-n, --calls` | `0` | Total de chamadas; `0` = só a janela limita |
| `-H, --hold` | `30` | Duração da chamada atendida antes do BYE (s) |
| `-l, --max-concurrent` | cps x (hold+4) x 1,2 | Limite de simultâneas no SIPp |
| `-M, --media` | `rtp` | `rtp` ou `none` (seção 14) |
| `--did` | — | Todas as chamadas para um único DID |
| `--web-duration` | `30` | Duração de cada alvo web (s) |
| `--web-conns` / `--web-threads` | `50` / `4` | Conexões e threads do `wrk` |
| `--mysql-duration` | `60` | Duração do sysbench (s) |
| `--baseline` / `--cooldown` | config | Sobrescrevem `BASELINE_SECONDS` / `COOLDOWN_SECONDS` |
| `--label` | — | Rótulo no nome do diretório de resultado |
| `--fs-password` | — | Pede a senha do `fs_cli` no terminal |
| `--dry-run` | — | Mostra o plano e a linha do SIPp, sem executar nada |
| `--confirm-prod` | — | **Obrigatório** para executar (ambiente de produção) |
| `-y, --yes` | — | Não pede a palavra `PRODUCAO` no terminal |

Simultâneas em regime = CPS x hold. O plano avisa quando `--max-concurrent` fica
abaixo disso. Com `UAS_PORT`, o plano mostra o atendedor; sem ele, estima o volume
gravado na caixa postal com `--media rtp`.

### 7.5 `report` — regenerar o relatório

**Função:** refazer o `report.txt` a partir dos dados brutos de uma execução (útil
depois de atualizar o script). Não precisa de configuração nem de SSH.

```bash
./flux-loadtest.sh report /var/lib/flux-loadtest/results/20261007-120000-c1000-cps100
```

### 7.6 `zabbix` — integração com o Zabbix

**Função:** criar os hosts no Zabbix, importar uma execução e testar a conexão. O
envio ao vivo não tem comando próprio: o `run` faz quando `ZABBIX_SERVER` está
preenchido (seção 19).

| Subcomando | O que faz |
|---|---|
| `setup [--import-template]` | Cria o grupo `Flux Loadtest` e um host por servidor da configuração, mais `gen` e `run`, e vincula os templates. `--import-template` importa (ou atualiza) os templates antes |
| `send <diretório> [--force] [--dry-run]` | Envia uma execução com os timestamps originais. Recusa uma execução já enviada (`zabbix.sent`), porque o Zabbix duplicaria os valores; `--force` reenvia |
| `check` | Versão da API, hosts com o prefixo e um valor de teste no trapper |

```bash
./flux-loadtest.sh zabbix setup --import-template
```

```bash
./flux-loadtest.sh zabbix send /var/lib/flux-loadtest/results/20261007-120000-c1000-cps100
```

## 8. Exemplos de testes

Siga a ordem: cada passo valida o anterior.

### 8.1 Validação inicial

```bash
./flux-loadtest.sh check --fs-password
```

```bash
./flux-loadtest.sh smoke --media none
```

```bash
./flux-loadtest.sh smoke --media rtp
```

### 8.2 Piloto (1 CPS, 60 s)

Revisar o plano:

```bash
./flux-loadtest.sh run --dry-run -t sip -r 1 -H 10 -w 60 --media none
```

Executar:

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 1 -H 10 -w 60 --media none --baseline 30 --cooldown 30 --label piloto
```

Esperado: 0 falhas, chamadas encerradas por "fim do hold".

### 8.3 Degraus das metas da issue

| Simultâneas | 100 CPS | 200 CPS | 300 CPS |
|---|---|---|---|
| 1000 | `-r 100 -H 10` | `-r 200 -H 5` | `-r 300 -H 4` |
| 2000 | `-r 100 -H 20` | `-r 200 -H 10` | `-r 300 -H 7` |
| 3000 | `-r 100 -H 30` | `-r 200 -H 15` | `-r 300 -H 10` |

Use `-w` de pelo menos `hold + 120` para o regime se estabilizar depois da rampa e
suba um degrau por execução, comparando os relatórios:

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 100 -H 10 -w 300 --label c1000-cps100
```

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 100 -H 30 -w 600 --label c3000-cps100
```

Antes das metas maiores, confira no `check` os limites de cada FS: no repositório,
`switch.conf.xml` traz `max-sessions` 1000 e `sessions-per-second` 30 por nó.

### 8.4 Um FreeSWITCH direto, sem OpenSIPS

Valida o script e um nó isolado (o `load_balancer` não entra). No `loadtest.conf`,
deixe vazios `OPENSIPS_HOST`, `DB_HOSTS` e `WEB_HOST` e configure, por exemplo, o
`sbc-stfc-02`:

```
FS_HOSTS=200.159.177.162
SIP_TARGET=200.159.177.162:5070
```

Para o FS do `sbc-stfc-1`, use `200.159.177.163` com a porta `5070` (a `5060` é o OpenSIPS).

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 5 -H 20 -w 180 --label fs-direto
```

### 8.5 Mídia: sinalização pura x RTP

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 50 -H 20 -w 300 -M none --label cps50-sem-rtp
```

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 50 -H 20 -w 300 -M rtp --label cps50-rtp
```

A diferença de `freeswitch_cpu_pct` e `net_*_pps` entre os dois mostra o custo de
mídia: com o atendedor, o FS ancora o RTP das duas pernas (originador e atendedor).

### 8.6 Rampa personalizada e total fixo de chamadas

De 20 a 200 CPS, +20 a cada 30 s, parando em 50 mil chamadas:

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 200 --cps-start 20 --ramp-step 20 --ramp-interval 30 -H 15 -w 900 -n 50000 --label rampa-200
```

### 8.7 Só web, e web + MySQL

```bash
./flux-loadtest.sh run --confirm-prod -t web --web-conns 50 --web-duration 60 --label web-c50
```

```bash
./flux-loadtest.sh run --confirm-prod -t web,mysql --web-conns 100 --mysql-duration 120 --label web-mysql
```

### 8.8 Todos os testes juntos (SIP + MySQL + Web)

Com `-t sip,web,mysql`, uma única execução roda as fases em sequência, com as métricas
de todos os servidores e um único relatório:

```
baseline -> sip -> sip_drain -> mysql_prepare -> mysql -> mysql_cleanup -> web_static -> web_php -> [web_extra] -> cooldown
```

Pré-requisitos além do `check`:

- **MySQL:** `MYSQL_BENCH_*` preenchidos e a VM de teste com acesso ao VIP. No STFC, o VIP
  172.17.4.100 só existe na rede interna: de uma VM externa, use `-t sip,web`.
- **Web:** `WEB_BASE_URL` preenchida (e, opcionalmente, `NGINX_STATUS_URL` / `FPM_STATUS_URL`).
- **FreeSWITCH com senha:** `--fs-password` ou `FS_CLI_PASSWORD_FILE`.

Revisar o plano de todos os testes antes:

```bash
./flux-loadtest.sh run --dry-run -t sip,web,mysql -r 20 -H 20 -w 300
```

Comando mínimo (as demais opções usam os padrões da tabela da seção 7.4):

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 20 -H 20 -w 300 --label todos
```

Mesmo teste com **todas as opções explícitas**:

```bash
./flux-loadtest.sh run -c /opt/flux-loadtest/loadtest.conf --confirm-prod --fs-password -t sip,web,mysql -r 50 --cps-start 5 --ramp-step 5 --ramp-interval 10 -H 20 -w 600 -n 0 -l 1440 -M none --web-duration 60 --web-conns 50 --web-threads 4 --mysql-duration 120 --baseline 60 --cooldown 60 --label todos-cps50
```

| Opção | Valor | Efeito neste exemplo |
|---|---|---|
| `-c` | `/opt/flux-loadtest/loadtest.conf` | Arquivo de configuração (padrão: ao lado do script) |
| `--confirm-prod` | — | Obrigatório para executar |
| `--fs-password` | — | Pede a senha do event socket do FreeSWITCH |
| `-t` | `sip,web,mysql` | Roda os três testes, nessa ordem |
| `-r` | `50` | CPS alvo |
| `--cps-start` / `--ramp-step` / `--ramp-interval` | `5` / `5` / `10` | Começa em 5 CPS e sobe 5 a cada 10 s: chega a 50 CPS em 90 s |
| `-H` | `20` | Cada chamada fica 20 s atendida antes do BYE |
| `-w` | `600` | Envia chamadas por 10 minutos |
| `-n` | `0` | Sem limite de quantidade (a janela é que encerra) |
| `-l` | `1440` | No máximo 1440 simultâneas (regime esperado: 50 x 20 = 1000) |
| `-M` | `none` | Sem RTP de origem (só sinalização) |
| `--web-duration` / `--web-conns` / `--web-threads` | `60` / `50` / `4` | Cada alvo web por 60 s, 50 conexões em 4 threads |
| `--mysql-duration` | `120` | sysbench por 2 minutos |
| `--baseline` / `--cooldown` | `60` / `60` | 1 minuto sem carga antes e depois |
| `--label` | `todos-cps50` | Nome do diretório de resultado |

Duração aproximada: baseline 60 s + SIP 600 s + drenagem ~25 s + 15 s + MySQL ~150 s +
15 s + web 2 x 70 s + cooldown 60 s = **~18 minutos**.

Todos os testes nas metas da issue (um degrau por execução):

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 100 -H 10 -w 300 --web-duration 60 --mysql-duration 120 --label todos-c1000-cps100
```

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 100 -H 20 -w 450 --web-duration 60 --mysql-duration 120 --label todos-c2000-cps100
```

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 100 -H 30 -w 600 --web-duration 60 --mysql-duration 120 --label todos-c3000-cps100
```

Todos os testes com RTP (mede também o custo de mídia nos FS):

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 50 -H 20 -w 300 -M rtp --label todos-rtp
```

Todos os testes de uma VM externa (sem acesso ao VIP), deixando o MySQL de fora:

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web -r 20 -H 20 -w 300 --label todos-externa
```

No laboratório (seção "Laboratório"): ligar a `vm-teste` à rede interna e rodar tudo:

```bash
./lab.sh interna
```

```bash
./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -y -t sip,web,mysql -r 10 -H 10 -w 120 --web-duration 20 --mysql-duration 30 --label lab-todos
```

### 8.9 Outros exemplos úteis

Todas as chamadas para um único DID:

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 5 -H 30 -w 120 --did 5500000000001 --label did-unico
```

Quantidade fixa de chamadas (para ao chegar em 10 mil ou ao fim da janela, o que vier primeiro):

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 50 -H 15 -w 900 -n 10000 --label n10000
```

Sem rampa (já começa no CPS alvo):

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 30 --cps-start 30 -H 20 -w 300 --label sem-rampa
```

Configuração alternativa (por exemplo, outro ambiente):

```bash
./flux-loadtest.sh check -c /etc/flux-loadtest/homologacao.conf
```

`smoke` para um DID específico, com e sem RTP:

```bash
./flux-loadtest.sh smoke --did 5500000000001 --media none
```

```bash
./flux-loadtest.sh smoke --did 5500000000001 --media rtp
```

Chaves SSH de uma VM atrás de NAT (IP público informado) e com primeiro acesso por admin:

```bash
./flux-loadtest.sh keys setup --from 203.0.113.50 --via admin --write-config
```

Só testar as chaves já instaladas:

```bash
./flux-loadtest.sh keys test
```

Regenerar o relatório de uma execução:

```bash
./flux-loadtest.sh report /var/lib/flux-loadtest/results/20261007-120000-todos-cps50
```

### 8.10 Execução sem interação

Com `FS_CLI_PASSWORD_FILE` configurado e `-y`, nada é pedido no terminal:

```bash
./flux-loadtest.sh run --confirm-prod -y -t sip -r 20 -H 20 -w 300 --label noturno
```

### 8.11 Encerrar a campanha

```bash
./flux-loadtest.sh keys revoke
```

### 8.12 Referência rápida

| Objetivo | Comando |
|---|---|
| Preparar as chaves SSH | `./flux-loadtest.sh keys setup --via admin --write-config` |
| Validar o ambiente | `./flux-loadtest.sh check --fs-password` |
| Uma chamada de teste | `./flux-loadtest.sh smoke --media none` |
| Ver o plano sem executar | `./flux-loadtest.sh run --dry-run -t sip,web,mysql -r 20 -H 20 -w 300` |
| Piloto SIP | `./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 1 -H 10 -w 60 --media none --label piloto` |
| Só SIP | `./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 100 -H 10 -w 300 --label sip` |
| Só web | `./flux-loadtest.sh run --confirm-prod -t web --web-conns 50 --web-duration 60 --label web` |
| Só MySQL | `./flux-loadtest.sh run --confirm-prod -t mysql --mysql-duration 120 --label mysql` |
| Todos os testes | `./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 20 -H 20 -w 300 --label todos` |
| Regenerar relatório | `./flux-loadtest.sh report <diretorio-da-execucao>` |
| Remover as chaves | `./flux-loadtest.sh keys revoke` |

## 9. Como o `run` funciona por dentro

### 9.1 Sequência

1. Valida opções, dependências e configuração; monta a lista de servidores e o SSH.
2. Conta os DIDs válidos e detecta o IP de origem SIP.
3. Mostra o plano. Com `--dry-run`, termina aqui.
4. Exige `--confirm-prod`, carrega a senha do `fs_cli` e pede `PRODUCAO` no terminal.
5. Cria `RESULTS_DIR/<data>-<label>/` e passa a gravar o console em `console.log`.
6. Testa o SSH de todos os servidores e registra a diferença de relógio.
7. Gera o CSV de chamadas, o áudio (se `rtp`) e o cenário SIPp.
8. Salva os snapshots `pre` e inicia os coletores em todos os servidores e na VM.
9. Executa as fases:

| Fase | O que acontece |
|---|---|
| `baseline` | Só coleta: o comportamento do ambiente sem a carga do teste |
| `sip` | SIPp com rampa até o CPS alvo, pela janela `-w` (ou até `-n` chamadas) |
| `sip_drain` | Sem novas chamadas; espera as ativas terminarem (até hold + 60 s) |
| `mysql_prepare` / `mysql` / `mysql_cleanup` | Cria a massa, roda o sysbench e remove as tabelas |
| `web_static` / `web_php` / `web_extra` | Um `wrk` por alvo, com 10 s de intervalo entre eles |
| `cooldown` | Só coleta: o retorno ao normal (roda mesmo após interrupção) |

10. Para os coletores, salva os snapshots `post`, gera o `report.txt` e o `.tar.gz`.

As fases ficam em `phases.tsv`; o relatório agrupa as métricas por elas.

### 9.2 Cenário SIP

`scenarios/uac-did.xml.in`, processado a cada execução:

1. Envia `INVITE sip:<DID>@<destino>` com SDP G.711 a-law (PCMA) e o header
   `X-Flux-Loadtest: <execução>`.
2. Mede INVITE -> 100 (RTD 1) e INVITE -> 200 (RTD 2).
3. Envia o ACK e, com `--media rtp`, inicia o áudio em loop.
4. Espera o BYE do FS por até `--hold`. Se ele vier antes, responde 200 e conta como
   "BYE remoto"; senão envia o próprio BYE ("fim do hold").
5. Respostas de erro ao INVITE (4xx/5xx) e timeouts contam como falha.

### 9.3 Parada suave

Ao fim da janela, ao estourar um limite ou com Ctrl+C, o SIPp recebe **um único**
`SIGUSR1`: para de criar chamadas e espera as ativas terminarem. Na versão 3.6.1, um
segundo `SIGUSR1` deixa o SIPp travado, por isso o script nunca o envia duas vezes.

O SIPp 3.6.1 às vezes também trava na saída suave, mesmo sem chamadas ativas
(observado no laboratório). Por isso, durante a drenagem, o script lê as estatísticas
do SIPp: quando não há chamadas ativas e sucesso + falha já somam o total criado, ele
encerra o processo com `SIGTERM`. Se o SIPp travar a ponto de parar de gravar
estatísticas, recebe `SIGTERM` depois de hold + 60 s.

### 9.4 Teste PHP e sessões

O CodeIgniter grava sessões no MySQL (`ci_sessions`). Sem cuidado, cada requisição
sem cookie criaria uma linha nova no banco de produção. Por isso o script obtém **um**
cookie com `curl` e o reutiliza em todas as requisições do `wrk`, com o mesmo
User-Agent (`sess_match_useragent`). Se não conseguir o cookie, o alvo é ignorado. O
arquivo do cookie é apagado no fim da fase.

## 10. Coletor de métricas

`lib/collector.sh` é enviado por `ssh ... bash -s` com `nice -n 10`. Ele lê `/proc`,
`df` e os comandos de status, escreve CSV no stdout e termina sozinho quando o SSH
cai ou o tempo máximo acaba. Não instala nada e não grava nada no servidor.

Convenções das colunas:

- `*_pct`: percentual. Nas colunas de processo (`freeswitch_cpu_pct`...), 100 = 1 núcleo.
- `*_s`: taxa por segundo no intervalo.
- `*_total`: contador acumulado; o relatório mostra a variação na fase.

Colunas comuns a todos os servidores:

| Grupo | Colunas |
|---|---|
| CPU | `cpu_pct`, `cpu_max_core_pct`, `cpu_max_core`, `iowait_pct`, `steal_pct`, `softirq_pct`, `load1` |
| Memória | `mem_used_pct`, `mem_avail_mb`, `swap_used_mb` |
| Rede | `net_rx_mbps`, `net_tx_mbps`, `net_rx_pps`, `net_tx_pps`, `udp_in_err_s`, `udp_rcvbuf_err_s` |
| Disco | `disk_rd_kbs`, `disk_wr_kbs`, `disk_busy_pct`, `disk_free_pct` |
| Processo | `<processo>_cpu_pct`, `<processo>_rss_mb`, `<processo>_threads` |

Colunas por papel:

| Papel | Processo | Colunas do serviço |
|---|---|---|
| FreeSWITCH | `freeswitch` | `fs_calls`, `fs_sessions`, `fs_sps`, `fs_idle_cpu` |
| OpenSIPS | `opensips` | `os_active_dlg`, `os_early_dlg`, `os_tm_inuse`, `os_rcv_req_s`, `os_failed_dlg_total`, `os_drop_req_total`, `os_shm_used_pct`, `os_load` |
| MySQL | `mysqld` | `db_qps`, `db_select_s`, `db_insert_s`, `db_update_s`, `db_threads_running`, `db_threads_connected`, `db_slow_total`, `db_row_lock_waits_total`, `db_repl_lag`, `db_repl_ok`, `db_wsrep_recv_queue`, `db_wsrep_send_queue`, `db_wsrep_fc_paused_pct`, `db_wsrep_cluster_size`, `db_wsrep_state`, `db_wsrep_primary`, `db_vip` |
| Web | `nginx`, `php-fpm` | `ngx_active`, `ngx_rps`, `ngx_writing`, `ngx_waiting`, `fpm_active`, `fpm_idle`, `fpm_listen_queue`, `fpm_rps`, `fpm_max_children_total`, `fpm_slow_total` |
| VM de teste | `sipp`, `wrk`, `sysbench` | — |

Processos são identificados pelo nome exato ou nome + versão (`php-fpm7.3`), para
não contar `mysqld_safe` ou `opensips-cli`.

Colunas do Percona XtraDB Cluster:

| Coluna | Significado |
|---|---|
| `db_wsrep_state` | Estado do nó (`wsrep_local_state`): `4` = Synced; `1` Joining, `2` Donor, `3` Joined |
| `db_wsrep_primary` | `1` = o nó faz parte do componente Primary (tem quórum) |
| `db_wsrep_cluster_size` | Quantidade de nós no cluster |
| `db_wsrep_fc_paused_pct` | Percentual do intervalo com a replicação pausada por flow control (nó atrasado travando as escritas) |
| `db_wsrep_recv_queue`, `db_wsrep_send_queue` | Filas de write-sets a aplicar e a enviar |
| `db_vip` | `1` = o VIP do keepalived está neste nó |

`db_repl_lag = -1` indica servidor sem replicação assíncrona, que é o normal no Percona
XtraDB Cluster.

## 11. Relatório e arquivos de saída

### 11.1 Seções do `report.txt`

| Seção | Conteúdo |
|---|---|
| Cabeçalho | Parâmetros da execução, VM de teste, destino e origem SIP |
| Linha do tempo | Início, fim e duração de cada fase |
| Limites de segurança | Se houve interrupção, o motivo e as últimas ocorrências |
| SIP | Criadas, sucesso, falhas por tipo, BYE remoto, fim do hold, pico de simultâneas, CPS, tempos INVITE -> 100 e -> 200, duração, falhas por motivo |
| MySQL | Transações, queries, latência média e p95 do sysbench |
| Web | req/s, latência média e p50/p90/p99, erros, por alvo |
| Relógio | Diferença de cada servidor para a VM |
| Servidores por fase | Uma tabela por servidor: métrica x fase |

Na tabela por servidor, cada célula é `média/pico`; `m` indica mínimo (disco livre,
memória disponível, CPU ociosa do FS) e `+` a variação de um contador.

### 11.2 Arquivos

| Arquivo | Conteúdo |
|---|---|
| `report.txt` | Relatório |
| `run.env`, `hosts.tsv` | Parâmetros e servidores da execução |
| `phases.tsv` | Fases com início e fim (epoch) |
| `metrics/<host>.csv` | Amostras brutas do coletor; `.err` com o stderr dele |
| `sip/` | `stats.csv`, `errors.log`, `actions.log`, `screen.log`, `calls.csv`, cenário gerado |
| `uas/` | Atendedor (com `UAS_PORT`): `stats.csv`, `errors.log`, `sipp.stderr`, `uas.xml` |
| `web/`, `mysql/` | Saídas completas do `wrk` e do `sysbench` |
| `snapshots/<host>-pre.txt`, `-post.txt` | Estado antes e depois (`status`, `lb_list`, réplica, PHP-FPM) |
| `guard.log` | Cada amostra acima de um limite |
| `abort.txt` | Motivo da interrupção (só quando houve) |
| `phases-start.tsv` | Início de cada fase, gravado na hora (usado pelo envio ao vivo) |
| `zabbix.log`, `zabbix.sent` | Log do envio ao Zabbix e marca de execução já enviada (servidor, prefixo, modo) |
| `clock.tsv`, `console.log` | Diferença de relógio e saída do terminal |

O diretório também é empacotado em `RESULTS_DIR/<execução>.tar.gz`.

## 12. Limites de segurança (guard)

A cada `SAMPLE_INTERVAL`, durante as fases de carga, o script lê a última amostra de
cada servidor e compara com os limites `GUARD_*` (seção 5.8). Quando um limite fica
estourado por `GUARD_HITS` amostras **seguidas**:

1. a carga para de forma suave (SIPp com um `SIGUSR1`; `wrk` e `sysbench` com `SIGTERM`);
2. as fases seguintes são canceladas;
3. o cooldown roda normalmente, e o relatório registra o motivo em "Limites de
   segurança" e em `abort.txt`;
4. o script termina com código 6.

No Percona XtraDB Cluster, também interrompem o teste: nó fora de Synced
(`wsrep_estado`), nó sem quórum (`wsrep_sem_quorum`), flow control acima de
`GUARD_MAX_WSREP_FC_PCT` e cluster menor que `GUARD_MIN_WSREP_CLUSTER_SIZE`.

Ctrl+C tem o mesmo efeito; um segundo Ctrl+C encerra a carga imediatamente. Um
coletor sem dados novos há mais de quatro intervalos gera um aviso.

Não reduza `GUARD_MIN_DISK_FREE_PCT` para "fazer o teste passar": disco quase cheio
no FS afeta a caixa postal, os logs e o banco interno do FreeSWITCH.

## 13. Segurança de credenciais

| Credencial | Como é tratada |
|---|---|
| Chave SSH | Ed25519 0600 na VM; instalada com `from=`, `no-pty` e sem encaminhamentos; `keys revoke` remove |
| Senha do `fs_cli` | `--fs-password` (digitada, sem eco) ou `FS_CLI_PASSWORD_FILE` (0600; o script avisa se outros usuários puderem ler) |
| Senha do MySQL (coleta) | Fica no servidor de banco (`--defaults-extra-file`); o script não a conhece |
| Senha do sysbench | Arquivo 0600 na VM; vai na linha de comando do `sysbench` (visível no `ps` da VM) |
| Cookie de sessão web | Sessão anônima, apagada no fim da fase web |

A senha do `fs_cli` trafega **só pelo stdin do SSH**: não aparece na linha de comando
do `ssh`, no `console.log`, no `run.env` nem no pacote de resultados. No servidor, ela
entra como `fs_cli -p ...` logo depois da palavra `fs_cli` do `FS_CLI_CMD` (funciona
com `sudo -n fs_cli -x`). Durante cada chamada do `fs_cli` (uma por amostra), ela fica
visível em `/proc/<pid>/cmdline` para outros usuários locais do FS. Se isso não for
aceitável, deixe `FS_CLI_PASSWORD_FILE` vazio e crie no servidor o `~/.fs_cli_conf` do
usuário que roda o `fs_cli` (com `sudo`, `/root/.fs_cli_conf`), com permissão 0600:

```
[default]
password => SENHA
```

Para gravar a senha em arquivo sem ela passar pelo histórico do shell:

```bash
install -m 0600 /dev/null /etc/flux-loadtest/fs_cli.pass
```

```bash
read -r -s -p "Senha: " p && printf '%s\n' "$p" > /etc/flux-loadtest/fs_cli.pass && unset p
```

## 14. Mídia

Com DIDs DIRECT-IP e o atendedor, o FS faz bridge entre a perna de entrada
(originador) e a de saída (atendedor). Com `bypass_media = 0` no DID (padrão), o FS
ancora o RTP das duas pernas: é o custo de mídia do tráfego de PBX por IP.

| Modo | Comportamento |
|---|---|
| `--media none` | Sem RTP nos dois SIPp. Mede sinalização, dialplan, MySQL e billing |
| `--media rtp` | Originador e atendedor transmitem um tom G.711 a-law (400 Hz / 1 kHz alternados) em loop: o FS recebe e repassa RTP nas duas pernas |

Variação adicional: DIDs com `bypass_media = 1` deixam o RTP fluir direto entre
originador e atendedor (o FS só sinaliza). Comparar as duas massas mostra quanto do
custo do FS é mídia.

Sem atendedor (destino na caixa postal), o FS atende e grava: cada chamada grava cerca
de `(hold - saudação) x 16 KB/s`, o plano mostra a estimativa, o limite de disco vigia
`FS_DISK_PATH` e `VM_BOXES` conta as mensagens nos snapshots.

## 15. Dimensionamento da VM de teste

Estimativa para o pior caso da issue (3000 simultâneas, 300 CPS, `--media rtp`), a
confirmar com as linhas `gen` do relatório de cada degrau:

| Recurso | Estimativa |
|---|---|
| CPU | 8 vCPU (dois SIPp, originador e atendedor, com a sinalização em ~1 núcleo cada; RTP nas threads do rtpstream) |
| Memória | 8 GB |
| Rede | 1 Gbps: com o atendedor, 2 x 3000 fluxos G.711 x ~90 kbit/s = ~540 Mbit/s por sentido, ~300 mil pps |
| Arquivos abertos | `ulimit -n` >= 3 x simultâneas por SIPp (o script tenta elevar para 65536) |

Com `--media none`, a VM de teste precisa de muito menos: no piloto a 1 CPS, o SIPp
usou ~4% de um núcleo. `GUARD_MAX_GEN_CPU_PCT` interrompe o teste se a própria VM
saturar, porque nesse caso os números deixam de representar os servidores.

## 16. Referência das funções

### 16.1 `flux-loadtest.sh`

**Base e configuração**

| Função | O que faz |
|---|---|
| `log`, `warn`, `die` | Mensagens com horário; `die` encerra com o código informado |
| `load_config` | Lê `CHAVE=valor` contra a lista de chaves conhecidas; remove aspas; recusa chave desconhecida |
| `is_uint`, `require_cfg`, `validate_config` | Validação de números, chaves obrigatórias, tipos e caminhos |
| `check_local_deps` | Confere comandos necessários na VM e o bash 5 |
| `usage`, `main` | Ajuda e roteamento das ações; `main` lê `-c` e carrega a configuração |

**Servidores e SSH**

| Função | O que faz |
|---|---|
| `add_host`, `build_hosts` | Monta a lista `opensips`, `fs1..N`, `db1..N`, `web` a partir da configuração |
| `has_role` | Indica se há servidor de um papel na execução |
| `build_ssh` | Monta o comando `ssh` (porta, `SSH_OPTS`, `known_hosts` dedicado, chave com `IdentitiesOnly`) |
| `remote` | Comando remoto curto, stdin desligado, timeout de 30 s |
| `remote_script` | Envia um script bash pelo stdin (não aparece na linha de comando) |
| `check_ssh_all` | Testa o SSH de todos os servidores, mede a diferença de relógio e lê o nome de cada um |
| `snapshot` | Salva o estado `pre`/`post` de cada servidor conforme o papel |

**Senha do fs_cli**

| Função | O que faz |
|---|---|
| `load_fs_password` | Obtém a senha (prompt ou arquivo), confere a permissão do arquivo e se `FS_CLI_CMD` tem `fs_cli` |
| `fs_prelude` | Gera o preâmbulo remoto que define `fsx()` = `FS_CLI_CMD` com `-p` |

**SIP**

| Função | O que faz |
|---|---|
| `parse_sip_target`, `detect_local_ip` | Valida `SIP_TARGET` e descobre o IP de origem pela rota |
| `build_calls_csv` | Gera o CSV do SIPp com os DIDs válidos embaralhados e o número de A |
| `build_rtp_file` | Gera 20 s de tom G.711 a-law (codificador em Python puro) |
| `render_scenario` | Preenche um modelo de cenário (hold ou espera do BYE, porta de mídia, RTP, id da execução) |
| `sipp_args`, `prepare_sip` | Monta a linha do SIPp (rampa, limites, arquivos de estatística e erro) |
| `raise_nofile` | Eleva `ulimit -n` e avisa se ficar abaixo do necessário |
| `run_sip_phase` | Executa o SIPp, vigia os limites e controla janela, drenagem e `SIGTERM` de segurança |
| `sip_all_done` | Pelas estatísticas do SIPp, indica se todas as chamadas criadas já terminaram |
| `uas_enabled`, `uas_port_free` | Atendedor configurado (`UAS_PORT`) e porta UDP livre na VM (`ss`) |
| `uas_args`, `prepare_uas` | Gera `uas/uas.xml` (cenário `uas-answer.xml.in`) e a linha do SIPp atendedor |
| `start_uas`, `stop_uas` | Sobe o atendedor no início da fase `sip` (falha se a porta não abrir) e o encerra com um `SIGUSR1` depois da drenagem (`SIGTERM` após 15 s) |
| `sipp_last`, `report_uas` | Última linha do `stats.csv`; seção "Atendedor" do relatório (recebidas, atendidas, falhas, originadas que não chegaram) |
| `wrk_url` | Coloca a porta explícita na URL do `wrk` (Debian mínimo sem `/etc/services`) |
| `sipp_soft_stop` | Envia um único `SIGUSR1` ao SIPp |

**Fases, coleta e limites**

| Função | O que faz |
|---|---|
| `now`, `phase_begin`, `phase_end`, `wait_seconds` | Controle das fases e de esperas interrompíveis |
| `collector_args` | Argumentos do coletor por papel (processos, disco, comando de status) |
| `start_collectors`, `stop_collectors` | Inicia os coletores remotos e o local; encerra e mostra erros deles |
| `host_violations` | Lê a última amostra de um servidor e lista os limites estourados |
| `sip_fail_pct` | Taxa de falha SIP do último período do SIPp |
| `guard_check` | Conta amostras seguidas acima do limite, grava `guard.log` e decide a interrupção |
| `stop_load` | Para a carga em andamento (SIPp suave; `wrk`/`sysbench` com `SIGTERM`) |
| `on_interrupt`, `on_exit` | Tratamento de Ctrl+C/`SIGTERM` e limpeza final (inclui relatório parcial) |
| `run_guarded` | Executa um comando de carga em segundo plano vigiando os limites |
| `run_mysql_phase` | Cria o schema isolado, roda prepare/run/cleanup do sysbench |
| `web_session_cookie`, `run_web_phase` | Obtém o cookie de sessão e roda o `wrk` em cada alvo |

**Opções, plano e ações**

| Função | O que faz |
|---|---|
| `parse_run_opts`, `validate_run_opts`, `has_test` | Opções do `run`/`smoke` e cálculo dos padrões derivados |
| `print_plan`, `save_run_env`, `write_hosts_tsv` | Plano da execução (com estimativas), registro dos parâmetros e dos servidores (com o nome de cada um) |
| `cmd_check`, `cmd_smoke`, `cmd_run` | Implementação das ações |

**Relatório**

| Função | O que faz |
|---|---|
| `generate_report` | Monta o `report.txt` completo |
| `report_sip` | Resumo do SIPp e falhas por motivo |
| `sip_real_errors` | Filtra do `errors.log` o que não é falha ("fim do hold", resolução de nome) |
| `report_hosts` | Tabela métrica x fase de cada servidor |
| `report_wrk`, `report_sysbench` | Resumos do `wrk` e do `sysbench` |
| `fmt_rt_ms` | Converte o tempo do SIPp (`HH:MM:SS:us`) para milissegundos |

**Chaves SSH**

| Função | O que faz |
|---|---|
| `cmd_keys`, `parse_keys_opts` | Roteamento dos subcomandos e validação das opções |
| `key_hosts` | Lista de endereços únicos (um servidor pode ter mais de um papel) |
| `keys_create` | Gera a chave e, com `--write-config`, grava `SSH_KEY` |
| `keys_trust`, `known_hosts_file`, `known_hosts_name` | `ssh-keyscan`, conferência e gravação no `known_hosts` |
| `key_from_for` | IP de origem usado no `from=` de cada servidor |
| `read_pubkey` | Lê e valida a chave pública |
| `deploy_script`, `remote_bootstrap` | Script POSIX que instala a linha; enviado em base64 com acesso por senha ou `--via` + `sudo` |
| `keys_deploy`, `keys_test`, `keys_revoke` | Instalação, teste e remoção |
| `confirm`, `set_config_value` | Confirmação interativa e gravação de chave na configuração (com backup) |

**Zabbix**

| Função | O que faz |
|---|---|
| `zbx_enabled`, `zbx_trap_args`, `zbx_api_args` | `ZABBIX_SERVER` preenchido; argumentos do trapper e da API para o `lib/flux_zabbix.py` |
| `zabbix_live_start`, `zabbix_live_stop` | Inicia o envio ao vivo depois dos coletores; no fim (ou na saída por erro) pede o envio final e espera até 60 s |
| `cmd_zabbix`, `usage_zabbix` | Subcomandos `setup`, `send` e `check` |

### 16.2 `lib/collector.sh`

| Função | O que faz |
|---|---|
| `read_cpu`, `save_cpu` | Tempos de CPU total e por núcleo (`/proc/stat`) |
| `read_net`, `read_udp` | Bytes e pacotes de rede (`/proc/net/dev`); erros UDP (`/proc/net/snmp`) |
| `read_disk`, `disk_free_pct` | Leitura, escrita e ocupação dos discos (`/proc/diskstats`); espaço livre (`df`) |
| `read_uptime_ticks`, `sample_procs`, `save_procs`, `proc_group_name` | CPU, memória e threads dos processos do serviço |
| `run_app`, `json_num` | Executa o comando de status com timeout; extrai números de JSON simples |
| `counter_rate` | Transforma contador acumulado em taxa por segundo |
| `app_header`, `app_sample` | Colunas e amostra das métricas do serviço por papel (inclui Percona XtraDB Cluster e VIP no banco) |
| `rate`, `now_us`, `fmt1`, `fmt2` | Taxas com o intervalo real e formatação decimal sem depender de locale |

### 16.3 `lib/flux_zabbix.py`

| Classe / função | O que faz |
|---|---|
| `Sender` | Protocolo do trapper (`ZBXD\x01`, lotes de 250 valores); mantém a fila se o Zabbix cair (modo ao vivo) |
| `Tail` | Lê só linhas completas novas de um arquivo ainda em escrita |
| `RunReader` | Converte o diretório da execução em valores: `metrics/*.csv`, `sip/stats.csv`, `uas/stats.csv`, fases, `guard.log`, `wrk`, `sysbench`, `run.env` e o resultado final |
| `parse_wrk`, `parse_sysbench_summary` | Extraem req/s, latências, erros, tps/qps |
| `cmd_send`, `cmd_setup`, `cmd_check`, `cmd_bootstrap` | Subcomandos; `bootstrap` é só do laboratório (senha inicial do Admin e token) |

## 17. Solução de problemas

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `smoke`: resposta 403 | Origem não autorizada no OpenSIPS | IP (público, se houver NAT) na tabela `address`, grupo 10 |
| `smoke`: resposta 407 ou 401 | Origem fora da ACL do FS (destino direto) | Liberar o IP na ACL de entrada do profile |
| Resposta 404 ou 480 | DID inexistente, sem destino, ou DID para ramal (caixa postal não é alcançada, seção 6.6) | Conferir o DID no banco: `call_type = 2` e `extensions` |
| Resposta 502, 503 ou 408 com atendedor | FS não alcança `IP:UAS_PORT` da VM (firewall, IP errado, atendedor parado) | `check` mostra a porta; liberar SIP e RTP dos FS para a VM; conferir `extensions` |
| "Originadas que nao chegaram aqui" > 0 | Chamadas recusadas antes do bridge (OpenSIPS, dialplan, limite de canais) | Ver "Falhas por motivo" do originador e o log do FS |
| Atendedor: "sem BYE no prazo" | FS não repassou o BYE (perda de pacote ou FS sobrecarregado) | Ver `uas/errors.log` e a CPU dos FS no relatório |
| Resposta 503 | Limite de canais do DID/conta, ou `max-sessions`/`sessions-per-second` do FS | Conferir `maxchannels` e o `check` |
| Timeout de retransmissão | Firewall, porta SIP errada, IP bloqueado pelo fail2ban, servidor lento | Testar a porta; whitelist do Event Guard |
| "receive timeout ... jumping to label" no `errors.log` | **Não é erro**: é o fim do hold, a VM envia o BYE | Nada; o relatório conta como "fim do hold" |
| Interrompido por `disco_livre` | Partição do FS ou do MySQL abaixo de 15% | Liberar espaço no servidor; não baixar o limite |
| `check`: "fs_cli sem resposta" | Senha do event socket ou permissão | `--fs-password`, `FS_CLI_PASSWORD_FILE` ou `sudo` no `FS_CLI_CMD` |
| Colunas `fs_*` vazias no relatório | `run` sem a senha do `fs_cli` | Usar `--fs-password` ou `FS_CLI_PASSWORD_FILE` também no `run` |
| `keys test` falha depois de funcionar | IP público mudou (NAT) | `keys deploy --from NOVO_IP` |
| SSH recusado após `deploy` por senha | fail2ban bloqueou por tentativas erradas | Whitelist do IP; conferir o jail do sshd |
| Interrompido por `wsrep_estado` ou `wsrep_sem_quorum` | Nó do cluster dessincronizado ou sem quórum | Verificar o cluster antes de repetir (`wsrep_local_state_comment`, `wsrep_cluster_status`) |
| Interrompido por `flow_control` | Um nó não acompanha as escritas e trava o cluster | Comparar `db_wsrep_recv_queue` dos dois nós; disco e CPU do nó atrasado |
| `--tests mysql` não conecta | VIP 172.17.4.100 fora do alcance da VM | Rodar o sysbench de uma VM na rede 172.17.4.0/24 |
| `wrk` sem resultado: "Servname not supported for ai_socktype" | Debian mínimo sem `/etc/services` (pacote `netbase`) | O script já passa a porta explícita na URL do `wrk`; instale o `netbase` se usar o `wrk` à mão |
| Página PHP com HTTP 500 e "authentication method unknown to the client" | PHP 7.3 não autentica no `caching_sha2_password` (padrão do MySQL 8.4) | Usuário da aplicação com `mysql_native_password` e `mysql_native_password=ON` no servidor |
| `zabbix.log`: "valores recusados" | Host ou item inexistente no Zabbix | `zabbix setup --import-template`; conferir `ZABBIX_HOST_PREFIX` |
| `zabbix send`: "execucao ja enviada" | A execução já foi enviada ao vivo ou importada | Só use `--force` se os valores não chegaram (ver `zabbix.log`) |
| Item do Zabbix sem "último valor" após importação | O Zabbix só mostra como último valor dados das últimas 24 h | Ver em Monitoramento > Últimos dados > Histórico, ou nos gráficos com o período da execução |
| `udp_rcvbuf_err_s` alto na VM com `--media rtp` | O rtpstream do SIPp não consome o RTP devolvido pelo FS | Esperado; não afeta o teste |
| Aviso de `ulimit -n` | Limite de arquivos abertos baixo | Rodar como root ou ajustar `/etc/security/limits.conf` |

## 18. Limitações

- Os timestamps são gerados em cada servidor; mantenha NTP/chrony ativo.
- As métricas de rede somam todas as interfaces exceto `lo`.
- O consumo de cada thread é atribuído ao último núcleo em que ela rodou no intervalo.
- O cenário cobre INVITE para DID (DIRECT-IP com atendedor, ou atendido no FS); não
  registra ramais (o registro de devices é validado à parte, `lab/sip/register.xml`).
- O envio ao Zabbix não usa criptografia (sem TLS/PSK no trapper): use em rede interna
  ou por um proxy Zabbix local à VM de teste.
- Os templates são gerados no formato do Zabbix 7.2, a versão de produção (7.2.3),
  validada no laboratório. O import aceita formatos de versões anteriores, então o
  mesmo YAML entra num 7.4; `zabbix/gen_templates.py --version` muda só o cabeçalho.

## 19. Zabbix

### 19.1 Como funciona

```
VM de teste                                         Zabbix (server ou proxy)
  run -> RUN_DIR (metrics/, sip/, phases, guard)      trapper :10051
           \-- lib/flux_zabbix.py send --follow ------> hosts <prefixo><id>
  zabbix send RUN_DIR (importação) -------------------/     itens dependentes (JSONPath)
```

- Nada muda nos servidores: o Zabbix recebe o que a VM de teste já coleta.
- **Ao vivo:** com `ZABBIX_SERVER` e `ZABBIX_LIVE=1`, o `run` inicia o envio depois dos
  coletores e lê os arquivos a cada 2 s. Se o Zabbix cair, os valores ficam na fila e o
  teste continua; o resultado vai para `zabbix.log`.
- **Importação:** `zabbix send` reenvia qualquer execução (inclusive antigas ou de
  produção copiadas para outra máquina) com os timestamps originais.

### 19.2 Hosts e templates

| Host | Templates | Origem dos dados |
|---|---|---|
| `<prefixo>opensips` | Sistema + OpenSIPS | `metrics/opensips.csv` |
| `<prefixo>fs1`, `fs2` | Sistema + FreeSWITCH | `metrics/fsN.csv` |
| `<prefixo>db1`, `db2` | Sistema + MySQL PXC | `metrics/dbN.csv` |
| `<prefixo>web` | Sistema + Web | `metrics/web.csv` |
| `<prefixo>gen` | Sistema + Gerador | `metrics/gen.csv` (macro `{$FLT.CPU.MAX}` = `GUARD_MAX_GEN_CPU_PCT`) |
| `<prefixo>run` | Execução | `run.env`, fases, `sip/stats.csv`, `uas/stats.csv`, `web/`, `mysql/`, `guard.log`, `abort.txt` |

Chaves trapper (o template extrai cada métrica do JSON por item dependente):

| Chave | Conteúdo |
|---|---|
| `flt.sys` | Colunas de sistema do coletor (CPU, memória, rede, disco) |
| `flt.app` | Colunas do serviço e dos processos (`fs_*`, `os_*`, `db_*`, `ngx_*`, `fpm_*`, `<processo>_cpu_pct`...) |
| `flt.sip` | Uma linha do `stats.csv` do SIPp: CPS alvo e real, simultâneas, sucesso/falha no período e acumulado, retransmissões, watchdog, INVITE->100/200 |
| `flt.uas` | Uma linha do `stats.csv` do atendedor: recebidas por segundo, simultâneas, sucesso/falha no período e acumulado, falhas sem BYE, duração |
| `flt.web` | Resultado do `wrk` por alvo (`static`, `php`, `extra`): req/s, latências p50/p90/p99, erros |
| `flt.mysql` | Intervalos (`*_now`) e resumo do `sysbench` |
| `flt.run.info`, `flt.phase`, `flt.guard`, `flt.result` | Parâmetros, fase em andamento, eventos do guard e resultado (`ok`/`interrompido`, totais SIP e do atendedor) |

Unidades convertidas no template: MB -> B, Mbps -> bps, kB/s -> B/s.

### 19.3 Gatilhos

Seguem os limites do guard (seção 12), com a mesma regra de 3 amostras seguidas, e
usam macros que podem ser ajustadas no host:

| Gatilho | Macro (padrão) |
|---|---|
| CPU, memória, disco livre | `{$FLT.CPU.MAX}` (85), `{$FLT.MEM.MAX}` (90), `{$FLT.DISK.FREE.MIN}` (15) |
| Descarte de UDP por buffer cheio | — |
| FreeSWITCH: CPU ociosa baixa, perto de `max-sessions` | `{$FLT.FS.IDLE.MIN}` (10), `{$FLT.FS.SESSIONS.MAX}` (900) |
| OpenSIPS: memória compartilhada | `{$FLT.OS.SHM.MAX}` (80) |
| PXC: tamanho do cluster, flow control, fora do Primary | `{$FLT.WSREP.SIZE.MIN}` (2), `{$FLT.WSREP.FC.MAX}` (10) |
| PHP-FPM com fila | — |
| Falhas SIP por período, watchdog do SIPp | `{$FLT.SIP.FAIL.MAX}` (5) |
| Execução interrompida | — (recupera na próxima execução `ok`) |

Os problemas se recuperam quando o valor volta ao normal ou quando os dados param por
`{$FLT.NODATA}` (5 min, fim do teste), e podem ser fechados manualmente.

### 19.4 Preparação (uma vez por Zabbix)

1. Token de API: *Users > API tokens*, para um usuário com escrita em hosts e templates.
   Grave num arquivo 0600 na VM de teste e aponte `ZABBIX_API_TOKEN_FILE`.
2. Liberar a VM de teste para o trapper (10051) do server ou de um proxy.
3. Preencher `ZABBIX_*` no `loadtest.conf` e rodar:

```bash
./flux-loadtest.sh zabbix setup --import-template
```

```bash
./flux-loadtest.sh zabbix check
```

O `check` geral também testa o Zabbix quando ele está configurado.

### 19.5 Atualizar os templates

Os templates são gerados a partir das colunas do coletor. Depois de mudar o
`lib/collector.sh`, atualize as listas em `zabbix/gen_templates.py`, gere de novo e
reimporte (`zabbix setup --import-template`):

```bash
python3 zabbix/gen_templates.py > zabbix/flux-loadtest-templates.yaml
```

### 19.6 Disparo pelo Zabbix

Perfis de teste pré-definidos podem ser iniciados e parados pela interface do Zabbix,
sem terminal. O fluxo:

```
Zabbix (menu Flux Loadtest do host <prefixo>gen)
  -> script global, executado pelo zabbix-agentd do servidor de testes (system.run)
     -> sudo -n /usr/local/sbin/flux-loadtest-zbx start <perfil>
        -> systemd-run (unidade flux-loadtest-zbx) -> flux-loadtest.sh run --confirm-prod -y ...
```

| Peça | Onde | Função |
|---|---|---|
| `profiles/*.conf.example` | `/etc/flux-loadtest/profiles.d/<perfil>.conf` | Parâmetros do `run` (`TESTS`, `CPS`, `WINDOW`, `HOLD`, `MEDIA`...), lidos como dado; `ZABBIX_ENABLED=1` publica o perfil |
| `bin/flux-loadtest-zbx` | `/usr/local/sbin` | Valida o perfil, aplica os tetos, dispara a unidade systemd e grava o estado (`/var/lib/flux-loadtest/zbx-state.json`) |
| Include do agent | `/etc/zabbix/zabbix_agentd.d/flux-loadtest.conf` | Gerado por `flux-loadtest-zbx agent-conf`: `UserParameter` de descoberta e estado, `AllowKey` exato por perfil e `DenyKey=system.run[*]` |
| Template `Flux Loadtest - Disparo` | host `<prefixo>gen` (interface agent) | Estado (30 s), descoberta dos perfis (10 min) e, por perfil, código, fim, resultado e diretório da última execução |
| Scripts globais | menu **Flux Loadtest** | Iniciar perfil (lista dos perfis, com confirmação), Plano (dry-run), Parar teste (com confirmação), Estado |

Gatilhos do template: teste em execução (informação), última execução interrompida
(código 6, guard ou "Parar teste"), última execução com falha (outros códigos) e agent sem
estado por `{$FLT.TRIG.NODATA}`.

**Segurança:**

- O agent executa `system.run` com `sh -c`. Por isso o include libera **só os comandos
  exatos** de cada perfil habilitado (sem `*`) e nega o resto. Validado com `zabbix_get`:
  `system.run[id]` e `...start piloto; id` são recusados.
- O usuário `zabbix` só pode rodar o wrapper pelo sudo. O wrapper revalida o nome do
  perfil (`[a-z0-9-]`), as chaves e os valores, e recusa CPS acima de `ZBX_MAX_CPS` e janela
  acima de `ZBX_MAX_WINDOW` (`/etc/flux-loadtest/zabbix-runner.conf`; padrões 50 CPS e 3600 s).
- Uma execução por vez (trava + unidade systemd única). "Parar teste" manda SIGINT só ao
  processo principal: parada suave, cooldown e relatório, como o Ctrl+C.
- Os scripts exigem permissão de escrita no host gen e podem ficar restritos a um grupo de
  usuários (`ZABBIX_SCRIPT_USRGRP`). O "Iniciar perfil" pede confirmação.
- Cada perfil roda com `--confirm-prod -y`. Revise os perfis como revisaria o comando: quem
  executa o script dispara a carga nos servidores reais.
- Com `TESTS` contendo `sip`, o `start` exige `FS_CLI_PASSWORD_FILE` no `loadtest.conf`
  (sem terminal, não há `--fs-password`).

**Preparação (servidor de testes, como root):**

```bash
install -d -m 0755 /etc/flux-loadtest/profiles.d && cp /opt/flux-loadtest/profiles/piloto.conf.example /etc/flux-loadtest/profiles.d/piloto.conf
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --zabbix-server IP_DO_ZABBIX_SERVER --dry-run
```

Sem `--dry-run`, o `prepare` instala o `zabbix-agent` 7.2 (se faltar), o wrapper, o sudoers e
o include, ajusta o `Server=` (modo passivo) e reinicia o agent. Repita depois de cada
mudança nos perfis (o `AllowKey` é por perfil). Confira com
`flux-host.sh check zabbix-agent`.

No `loadtest.conf`, `ZABBIX_GEN_AGENT` com o IP do agent (e, se quiser,
`ZABBIX_SCRIPT_USRGRP`). Depois:

```bash
./flux-loadtest.sh zabbix setup --import-template --scripts
```

O host `<prefixo>gen` ganha a interface agent (10050) e o template de disparo, e os scripts
são criados ou atualizados com a lista dos perfis. Rode de novo quando os perfis mudarem.

**Uso:** Monitoramento > Hosts, menu do host `<prefixo>gen` > Flux Loadtest > Iniciar perfil.
A execução aparece no host `<prefixo>run` (seção 19.2) e no relatório de sempre; o estado e o
código final, nos itens do template de disparo. Diagnóstico: `journalctl -u flux-loadtest-zbx`.

Validado com Zabbix 7.2.3 e zabbix-agent 7.2 em Debian 12 (com um `flux-loadtest.sh` falso):
importação do template, criação idempotente dos scripts, lista de perfis, recusa de valor fora
da lista, início, recusa de segundo início, parada suave com código 6, LLD e gatilhos. No 7.2,
script executado no agent tem timeout fixo de 30 s (o `plan` corta em 25 s).
