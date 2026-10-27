# loadtest.conf

O `loadtest.conf` fica ao lado do script ou é indicado com `-c ARQUIVO`. No STFC, use
`/etc/flux-loadtest/loadtest.conf` a partir de `deploy/stfc-completo/loadtest.conf`, que já vem
preenchido.

Regras do formato:

- `CHAVE=valor`, uma por linha, sem espaços ao redor do `=`;
- aspas envolventes são removidas; comentários só em linhas próprias (`#`);
- o arquivo é lido como **dado**, nunca executado: chave desconhecida é recusada (código 3);
- servidor com chave vazia fica fora do teste.

A coluna "STFC" mostra o valor usado na campanha quando ele difere do padrão.

## SSH

| Chave | Padrão | STFC | Descrição |
|---|---|---|---|
| `SSH_USER` | — | `loadtest` | Usuário nos servidores (obrigatório) |
| `SSH_KEY` | — | `/etc/flux-loadtest/id_ed25519` | Chave privada da VM (caminho absoluto); criada por `keys create` |
| `SSH_PORT` | `22` | | Porta SSH |
| `SSH_OPTS` | `-o BatchMode=yes -o ConnectTimeout=5 ...` | `+ StrictHostKeyChecking=yes` | Opções extras do `ssh` |
| `SSH_KNOWN_HOSTS` | vazio (`~/.ssh/known_hosts`) | `/etc/flux-loadtest/known_hosts` | `known_hosts` dedicado; preenchido por `keys trust` |
| `SSH_KEY_TYPE` | `ed25519` | | `ed25519` ou `rsa` (4096 bits) |
| `SSH_KEY_COMMENT` | `flux-loadtest@<host>-<data>` | | Comentário da chave |
| `SSH_KEY_FROM` | vazio (detecta pela rota) | | `from=` do `authorized_keys`; obrigatório atrás de NAT |

## Servidores

| Chave | STFC | Descrição |
|---|---|---|
| `OPENSIPS_HOST` | `200.159.177.163` | OpenSIPS |
| `FS_HOSTS` | `"200.159.177.163 200.159.177.162"` | FreeSWITCH, separados por espaço (viram `fs1`, `fs2`) |
| `DB_HOSTS` | `"200.159.177.161 200.159.177.164"` | Nós do cluster (viram `db1`, `db2`) |
| `WEB_HOST` | vazio na campanha (o gerador é o `.165`) | Servidor web (nginx + PHP-FPM) |

Numa VM de teste dentro da rede interna, use os IPs 172.17.4.x.

## SIP

| Chave | Padrão | STFC | Descrição |
|---|---|---|---|
| `SIP_TARGET` | — | `200.159.177.163:5060` | Destino das chamadas, `IP:porta`. FS direto: `:5070` |
| `SIP_LOCAL_IP` | vazio (detecta pela rota) | `200.159.177.165` | IP de origem do SIPp |
| `SIP_LOCAL_PORT` | `5060` | | Porta de origem do SIPp |
| `DID_FILE` | — | `/etc/flux-loadtest/dids.txt` | Um DID por linha; aceita `#` e linhas vazias |
| `CALLER_ID` | — | `550000009999` | Número de A (facilita filtrar CDRs) |
| `RTP_PORT_BASE` | `20000` | | Porta base de RTP do originador |
| `SIP_RECV_TIMEOUT_MS` | `60000` | | Espera máxima pelo 200 OK; depois a chamada conta como falha |
| `UAS_PORT` | vazio | `5090` | Porta do atendedor; vazio = sem atendedor |
| `UAS_RTP_PORT_BASE` | `40000` | | Porta base de RTP do atendedor (diferente de `RTP_PORT_BASE`) |

## FreeSWITCH

| Chave | Padrão | STFC | Descrição |
|---|---|---|---|
| `FS_CLI_CMD` | `fs_cli -x` | `sudo -n fs_cli -x` | Comando no servidor (aceita `-H`/`-P`) |
| `FS_CLI_PASSWORD_FILE` | vazio | `/etc/flux-loadtest/fs_cli.pass` | Arquivo 0600 com a senha do event socket |
| `FS_DISK_PATH` | `/var/lib/freeswitch` | | Partição vigiada pelo limite de disco |
| `VM_BOXES` | vazio | | Caixas postais de teste (`ramal@dominio`) contadas antes e depois |
| `VM_GREETING_SECONDS` | `8` | | Duração da saudação (estimativa de disco) |
| `VM_BYTES_PER_SECOND` | `16000` | | Bytes/s gravados por chamada (WAV 8 kHz 16 bit) |

## OpenSIPS, MySQL e web (coleta)

| Chave | Padrão | STFC | Descrição |
|---|---|---|---|
| `OPENSIPS_MI_CMD` | `opensips-cli -x mi` | `sudo -n opensips-cli -x mi` | Comando MI |
| `MYSQL_CLI_CMD` | `mysql` | `mysql --defaults-extra-file=/etc/mysql/flux-loadtest.cnf` | Cliente no servidor de banco |
| `MYSQL_DISK_PATH` | `/var/lib/mysql` | | Partição de dados |
| `FLUX_DB_NAME` | `flux` | | Schema do Flux; o sysbench se recusa a usar este nome |
| `DB_VIP` | vazio | `172.17.4.100` | VIP do keepalived; o coletor marca em qual nó ele está |
| `NGINX_STATUS_URL` | vazio | `http://127.0.0.1/nginx_status` | Lida no próprio servidor web |
| `FPM_STATUS_URL` | vazio | `http://127.0.0.1/fpm-status?json` | Lida no próprio servidor web |
| `WEB_PROCS` | `nginx,php-fpm` | | Processos somados no servidor web |

## Web (carga com `wrk`)

| Chave | Padrão | Descrição |
|---|---|---|
| `WEB_BASE_URL` | — | URL base a partir da VM (obrigatória com `--tests web`). STFC: `https://200.159.177.165` |
| `WEB_STATIC_PATH` | `/assets/images/addon_icon.png` | Alvo estático (só nginx) |
| `WEB_PHP_PATH` | `/` | Alvo PHP (nginx + PHP-FPM + sessão) |
| `WEB_EXTRA_PATH` | vazio | Terceiro alvo opcional |
| `WEB_TLS_INSECURE` | `1` | Aceita certificado autoassinado no `curl` |
| `WEB_REUSE_SESSION` | `1` | Reutiliza um único cookie de sessão (evita uma linha nova em `ci_sessions` por requisição) |
| `WEB_SESSION_COOKIE` | `ci_session` | Nome do cookie de sessão do CodeIgniter |

## MySQL (carga com `sysbench`)

| Chave | Padrão | Descrição |
|---|---|---|
| `MYSQL_BENCH_HOST` / `MYSQL_BENCH_PORT` | — / `3306` | VIP, a partir da VM. STFC: `172.17.4.100` (só na rede interna) |
| `MYSQL_BENCH_USER` | — | Usuário com `ALL` só no schema de teste |
| `MYSQL_BENCH_PASSWORD_FILE` | — | Arquivo 0600 com a senha |
| `MYSQL_BENCH_DB` | `loadtest` | Schema isolado (nunca o do Flux) |
| `MYSQL_BENCH_TABLES` / `MYSQL_BENCH_TABLE_SIZE` | `4` / `100000` | Tamanho da massa |
| `MYSQL_BENCH_THREADS` | `8` | Conexões simultâneas |
| `MYSQL_BENCH_EXTRA_ARGS` | vazio | Ex.: `--mysql-ssl=on` |

## Limites de segurança e coleta

| Chave | Padrão | STFC | Descrição |
|---|---|---|---|
| `GUARD_MAX_CPU_PCT` | `85` | `75` | CPU total de um servidor |
| `GUARD_MAX_GEN_CPU_PCT` | `90` | `70` | CPU da própria VM de teste |
| `GUARD_MAX_MEM_PCT` | `90` | `85` | Memória usada |
| `GUARD_MIN_DISK_FREE_PCT` | `15` | | Disco livre mínimo (`FS_DISK_PATH`, `MYSQL_DISK_PATH`, `/`) |
| `GUARD_MAX_FAIL_PCT` | `5` | `2` | Falha SIP no período (mínimo de 10 chamadas) |
| `GUARD_MAX_REPL_LAG` | `30` | | Atraso de replicação assíncrona (s); não se aplica ao PXC |
| `GUARD_MAX_WSREP_FC_PCT` | `10` | | Fração do intervalo com a replicação pausada por flow control (`0` desliga) |
| `GUARD_MIN_WSREP_CLUSTER_SIZE` | `0` | `2` | Tamanho mínimo do cluster (`0` desliga) |
| `GUARD_MAX_CORE_PCT` | `0` (desligado) | | Núcleo mais carregado (o FS tem uma thread que ocupa ~95% de um núcleo) |
| `GUARD_HITS` | `3` | | Amostras seguidas acima do limite para interromper |
| `SAMPLE_INTERVAL` | `5` | | Intervalo de coleta (s) |
| `BASELINE_SECONDS` / `COOLDOWN_SECONDS` | `60` / `60` | `120` / `120` | Fases sem carga antes e depois |
| `CAPACITY_ALERT_PCT` | `80` | | Alerta da foto de capacidade |
| `RESULTS_DIR` | `/var/lib/flux-loadtest/results` | | Onde os resultados são gravados |

Os limites do guard são explicados em [Segurança](../referencia/seguranca.md#limites-de-seguranca-guard).

!!! warning "Não afrouxe o disco"
    Não reduza `GUARD_MIN_DISK_FREE_PCT` para "fazer o teste passar": disco quase cheio no FS
    afeta a caixa postal, os logs e o banco interno do FreeSWITCH.

## Zabbix (opcional)

| Chave | Padrão | Descrição |
|---|---|---|
| `ZABBIX_SERVER` | vazio (sem Zabbix) | Server ou proxy que recebe os valores por trapper |
| `ZABBIX_PORT` | `10051` | Porta do trapper |
| `ZABBIX_HOST_PREFIX` | `flt-` | Prefixo dos hosts (`flt-fs1`, `flt-run`...) |
| `ZABBIX_LIVE` | `1` | `1` envia durante o `run`; `0` só pela importação |
| `ZABBIX_API_URL` | vazio | `https://.../api_jsonrpc.php`; usada por `zabbix setup` e `zabbix check` |
| `ZABBIX_API_TOKEN_FILE` | vazio | Arquivo 0600 com o token (64 hexadecimais) |
| `ZABBIX_TLS_INSECURE` | `0` | `1` aceita certificado autoassinado na API |
| `ZABBIX_GEN_AGENT` | vazio | IP pelo qual o Zabbix alcança o agent da VM de teste (disparo de perfis) |
| `ZABBIX_SCRIPT_USRGRP` | vazio | Grupo de usuários que pode executar os scripts do menu |
| `ZABBIX_PROFILES_DIR` | `/etc/flux-loadtest/profiles.d` | Perfis publicados no menu |

Uso das chaves em [Zabbix](zabbix.md).
