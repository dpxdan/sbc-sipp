# Laboratório STFC em Docker

Réplica leve do ambiente STFC para validar o `flux-loadtest` sem tocar na produção.
Seis containers Debian 12 com os mesmos nomes, papéis e finais de IP dos servidores
reais. O banco e a web são reais e na mesma versão; o OpenSIPS e os FreeSWITCH são
simulados com SIPp. Um Zabbix 7.4 (server, web e PostgreSQL) recebe as amostras dos
testes, e a interface web, o Zabbix e o SSH dos servidores ficam acessíveis pelo macOS.

## Topologia

| Container (hostname) | Rede interna 172.30.4.0/24 | Rede "pública" 172.30.177.0/24 | O que roda |
|---|---|---|---|
| `sbc-stfc-1` | .163 | .163 | "OpenSIPS" :5060 e "FreeSWITCH" :5070 simulados; `fs_cli` e `opensips-cli` simulados |
| `sbc-stfc-02` | .162 | .162 | "FreeSWITCH" :5070 simulado |
| `banco-master-sbc-stfc` | .161 | .161 | Percona XtraDB Cluster 8.4.10-10 + keepalived (VIP .100, prioridade 150) |
| `banco-slave-stfc` | .164 | .164 | Percona XtraDB Cluster 8.4.10-10 + keepalived (prioridade 100) |
| `sbc-stfc-interfaceweb` | .165 | .165 | nginx 1.22.1 + PHP-FPM 7.3.33; página PHP com sessão no banco pelo VIP |
| `vm-teste` | — | .50 | VM originadora: SIPp, wrk, sysbench; o repositório montado em `/opt/flux-loadtest` |
| `zabbix-server` | — (zbx .10) | .10 | Zabbix server 7.4 (trapper 10051) |
| `zabbix-web` | — (zbx .11) | .11 | Frontend e API do Zabbix (8080) |
| `zabbix-db` | — (zbx .5) | — | PostgreSQL 17 do Zabbix; dados no volume `zbx-db` |

Equivalência com a produção:

| Produção | Laboratório | Motivo |
|---|---|---|
| 172.17.4.0/24 | 172.30.4.0/24 | 172.17.0.0/16 é a rede padrão do Docker e 172.18.0.0/16 já está em uso por outro projeto |
| — | 172.30.10.0/24 (`zbx`) | Rede do Zabbix com o PostgreSQL; server e web também ficam na rede "pública" |
| 200.159.177.x | 172.30.177.x (mesmos finais) | Rede "pública" simulada |
| VIP 172.17.4.100 | VIP 172.30.4.100 | — |

Como na VM do Parallels, a `vm-teste` fica só na rede "pública" e **não alcança o VIP**.
Para testar o sysbench, ligue-a à rede interna com `./lab.sh interna`.

Todos os servidores têm o sshd e os usuários `loadtest` e `admin` (com sudo), com
senhas aleatórias geradas no `.env`. O `loadtest` pode rodar `fs_cli` e
`opensips-cli` com `sudo -n`, como no sudoers sugerido para a produção.

## Acesso pelo macOS

O Docker Desktop não roteia do Mac para os IPs dos containers: as portas abaixo são
publicadas só em `127.0.0.1` e podem ser trocadas no `.env` (`LAB_PORT_*`). O
`./lab.sh status` mostra a lista atual.

| Serviço | Endereço no Mac | Variável |
|---|---|---|
| Interface web (nginx + PHP-FPM) | `https://127.0.0.1:8443/` (certificado autoassinado), `http://127.0.0.1:8081/` | `LAB_PORT_WEB_HTTPS`, `LAB_PORT_WEB_HTTP` |
| Zabbix (frontend e API) | `http://127.0.0.1:8080/` (usuário `Admin`, senha em `out/zabbix_admin.pass`) | `LAB_PORT_ZABBIX_WEB` |
| Zabbix trapper | `127.0.0.1:10051` | `LAB_PORT_ZABBIX_TRAPPER` |
| SSH `sbc-stfc-1` / `sbc-stfc-02` | `127.0.0.1:22163` / `:22162` | `LAB_PORT_SSH_SBC1` / `_SBC2` |
| SSH `banco-master-sbc-stfc` / `banco-slave-stfc` | `127.0.0.1:22161` / `:22164` | `LAB_PORT_SSH_DB1` / `_DB2` |
| SSH `sbc-stfc-interfaceweb` | `127.0.0.1:22165` | `LAB_PORT_SSH_WEB` |

SSH com os usuários `loadtest` ou `admin` (senhas no `.env`, só do laboratório):

```bash
ssh -p 22163 admin@127.0.0.1
```

Uma execução feita no Mac também pode ser importada no Zabbix do laboratório:

```bash
python3 lib/flux_zabbix.py send lab/out/results/EXECUCAO --server 127.0.0.1 --prefix lab-
```

## Zabbix

O `up` (ou `./lab.sh zabbix`) troca a senha inicial do `Admin` pela do `.env`, cria o
token de API (`out/zabbix_api.token`), importa os templates, cria os hosts `lab-*` e
desativa o host padrão "Zabbix server" (a imagem não tem agente). A configuração gerada
(`out/loadtest.conf`) já vem com `ZABBIX_*`, então todo `run` envia as amostras ao vivo.

No frontend: *Monitoramento > Hosts*, grupo `Flux Loadtest`; os gráficos ficam em cada
host (`lab-run` tem SIPp, wrk e sysbench). Detalhes dos templates na seção 19 do
README principal.

O histórico fica no volume `zbx-db` e sobrevive ao `down`; para apagar, use
`./lab.sh down --zabbix`.

## O que é real e o que é simulado

| Componente | Situação |
|---|---|
| Debian 12, sshd, sudo, `/proc` | Real |
| Percona XtraDB Cluster 8.4.10 (2 nós, SST, quórum) + keepalived | Real. Diferença: `pxc-encrypt-cluster-traffic=OFF` |
| nginx 1.22.1, PHP-FPM 7.3.33 (`stub_status`, `/fpm-status`) | Real |
| Sessão do CodeIgniter | Simulada pela `index.php`: grava em `flux.ci_sessions` como o CI |
| OpenSIPS e FreeSWITCH | **Simulados** com SIPp (processos com o nome `opensips` e `freeswitch`). Atendem como a caixa postal; não há `load_balancer`, dialplan nem RTP de volta |
| `fs_cli` / `opensips-cli` | Simulados. O `fs_cli` exige a senha do event socket; os números (chamadas, sessões) vêm do SIPp |
| Zabbix 7.4.15 (imagens oficiais `ubuntu-7.4.15`) + PostgreSQL 17 | Real |

O laboratório serve para validar o script (chaves SSH, coleta, limites, relatório,
cluster, VIP, sessão web), não para medir a capacidade de VoIP.

## Uso

Requisitos: Docker Desktop em execução, com pelo menos 4 GB de memória para ele
(o laboratório com Zabbix usa cerca de 2,2 GB parado).

```bash
cd lab
```

```bash
./lab.sh up
```

O `up` gera o `.env` com senhas aleatórias (e acrescenta as que faltarem num `.env`
antigo), constrói as imagens (a primeira vez baixa os pacotes e leva alguns minutos),
sobe os containers, espera os dois nós do cluster ficarem `Synced`, gera a configuração
em `out/` (montada na `vm-teste` como `/etc/flux-loadtest`) e configura o Zabbix.

```bash
./lab.sh status
```

```bash
./lab.sh shell
```

Dentro da `vm-teste`:

```bash
cd /opt/flux-loadtest
```

Para instalar as chaves SSH (no Mac, fora da `vm-teste`):

```bash
./lab.sh keys
```

Ou, dentro da `vm-teste`, digitando a senha do `loadtest` (em `out/loadtest.pass`,
só do laboratório) em cada servidor:

```bash
./flux-loadtest.sh keys setup -c /etc/flux-loadtest/loadtest.conf
```

```bash
./flux-loadtest.sh check -c /etc/flux-loadtest/loadtest.conf
```

```bash
./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip,web -r 20 -H 10 -w 120 --label lab
```

O relatório fica em `out/results/` (no Mac) e em `/var/lib/flux-loadtest/results/`
(na `vm-teste`).

## Comandos do `lab.sh`

| Comando | O que faz |
|---|---|
| `up` | Gera o `.env`, constrói, sobe, espera o cluster, gera `out/loadtest.conf` e configura o Zabbix. Os servidores geram chaves de host novas a cada subida, então o `known_hosts` do laboratório é zerado |
| `zabbix` | Senha do `Admin`, token de API, templates e hosts `lab-*` no Zabbix (idempotente) |
| `keys` | Roda o `keys setup` na `vm-teste` respondendo, com `expect`, a senha do `loadtest` em cada servidor (só no laboratório) |
| `conf [--dids ARQ]` | Regenera `out/loadtest.conf`, `out/dids.txt` e os arquivos de senha. Sem `--dids`, gera 100 mil DIDs fictícios; com `--dids`, aceita uma lista simples ou o CSV `id;number;...` |
| `status` | Estado dos containers, do cluster (tamanho, Primary, Synced), do VIP, quantidade de linhas em `flux.ci_sessions`, teste do Zabbix e endereços de acesso pelo macOS |
| `shell` | Shell na `vm-teste` |
| `interna` / `externa` | Liga/desliga a `vm-teste` da rede interna (para `--tests mysql`) |
| `down [--zabbix]` | Remove containers e redes; os dados do laboratório são efêmeros. `--zabbix` apaga também o histórico do Zabbix |

## Testes possíveis

- **Fluxo completo do script:** `keys setup`, `check`, `smoke`, `run` com `sip,web`.
- **Senha do `fs_cli`:** o `check` sem `FS_CLI_PASSWORD_FILE` mostra o aviso de
  `fs_cli` sem resposta.
- **Sessões web:** com o cookie reutilizado, `SELECT COUNT(*) FROM flux.ci_sessions`
  cresce 1 por alvo PHP, não 1 por request.
- **Cluster e VIP:** pare o mysqld do `banco-master-sbc-stfc` durante um `run`
  (`docker compose exec banco-master-sbc-stfc pkill mysqld`): o VIP passa para o
  slave e o limite de tamanho do cluster interrompe o teste.
- **sysbench:** `./lab.sh interna` e `run ... -t mysql`.

## Limitações do laboratório

- **CPU compartilhada:** os 6 containers dividem as vCPUs da VM do Docker Desktop (2
  por padrão). Sob carga web, todos os "servidores" chegam a ~99% de CPU juntos, o
  limite de CPU dispara e o SIPp mostra "Overload warning: watchdog timer". Para
  cargas maiores, aumente as vCPUs do Docker Desktop.
- **keepalived:** a verificação do mysqld usa `timeout 5` e `fall 3` para o VIP não
  oscilar com a CPU disputada.
- **SST do nó 2:** o `banco-slave-stfc` espera o nó 1 aceitar conexões antes do SST e
  repete o SST até 3 vezes. Com a CPU disputada, o doador pode recusar o primeiro pedido
  ("WSREP has not yet prepared node for application use").
- **Autenticação PHP 7.3 x MySQL 8.4:** o usuário da página web usa
  `mysql_native_password` (habilitado com `mysql_native_password=ON`), porque o PHP
  7.3 não autentica no `caching_sha2_password`, padrão do 8.4.
- **Verificação:** o usuário `labcheck` (autenticado pelo root do sistema, sem senha)
  só lê `flux` e `loadtest`, para o `status` contar as sessões.

## Validação feita (2026-10-07)

| Teste | Resultado |
|---|---|
| `keys setup` (5 servidores) | Chaves instaladas com `from=172.30.177.50`; login por chave ok; sudo restrito a `fs_cli`/`opensips-cli` |
| `check` | Nomes dos servidores, `fs_cli` com senha, Percona 8.4.10-10.1 (2 nós, Primary, Synced), VIP, status do nginx e do PHP-FPM |
| `smoke` (`rtp` e `none`) | 1/1 |
| `run -t sip,web -r 20 -H 10 -w 60` | 1053 chamadas sem falha (pico de 244 simultâneas); estático ~11,7 mil req/s; PHP ~290 req/s com ~600 consultas/s no banco pelo VIP; **1 sessão criada** para todas as requisições PHP |
| Falha do master durante o `run` | `cluster_size=1` detectado; teste interrompido de forma suave em 3 amostras; VIP migrou para o slave; 554 chamadas sem falha |

## Validação do Zabbix (2026-10-14)

| Teste | Resultado |
|---|---|
| `up` com Zabbix 7.4.15 | Senha do Admin trocada, token criado, 7 templates importados, 8 hosts `lab-*`; segundo `up` só atualiza (idempotente) |
| `zabbix send` de execuções de 07/10 | 853 e 319 valores, nenhum recusado; reenvio bloqueado sem `--force` |
| `run -t sip,web -r 10 -H 10 -w 60` com envio ao vivo | 491 valores, nenhum recusado; itens dependentes sem erro; `flt.result[status]` = `ok`, 220 chamadas, pico de 71 simultâneas |
| Gatilhos | "Execução interrompida" abre com a importação do failover e fecha com a execução `ok`; watchdog do SIPp e descarte UDP disparam e se recuperam |
| Acesso pelo macOS | Zabbix (8080), interface web (8443/8081), trapper (10051) e SSH (22161-22165) respondem em 127.0.0.1 |

## DIDs

O padrão são 100 mil DIDs fictícios (`5551900000000` a `5551900099999`), porque o SIP é
simulado e qualquer número serve. A lista real de DIDs ativos pode ser usada aqui
(`./lab.sh conf --dids ARQUIVO`) para testar o volume, mas **não deve ser usada como
`DID_FILE` em produção**: os DIDs ativos encaminham para PBXs e números de clientes,
e o teste geraria chamadas reais.
