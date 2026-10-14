# Laboratório STFC em Docker

Réplica leve do ambiente STFC para validar o `flux-loadtest` sem tocar na produção.
Seis containers Debian 12 com os mesmos nomes, papéis e finais de IP dos servidores
reais. O banco e a web são reais e na mesma versão; o OpenSIPS e os FreeSWITCH são
simulados com SIPp.

## Topologia

| Container (hostname) | Rede interna 172.30.4.0/24 | Rede "pública" 172.30.177.0/24 | O que roda |
|---|---|---|---|
| `sbc-stfc-1` | .163 | .163 | "OpenSIPS" :5060 e "FreeSWITCH" :5070 simulados; `fs_cli` e `opensips-cli` simulados |
| `sbc-stfc-02` | .162 | .162 | "FreeSWITCH" :5070 simulado |
| `banco-master-sbc-stfc` | .161 | .161 | Percona XtraDB Cluster 8.4.10-10 + keepalived (VIP .100, prioridade 150) |
| `banco-slave-stfc` | .164 | .164 | Percona XtraDB Cluster 8.4.10-10 + keepalived (prioridade 100) |
| `sbc-stfc-interfaceweb` | .165 | .165 | nginx 1.22.1 + PHP-FPM 7.3.33; página PHP com sessão no banco pelo VIP |
| `vm-teste` | — | .50 | VM originadora: SIPp, wrk, sysbench; `misc/loadtest` montado em `/opt/flux-loadtest` |

Equivalência com a produção:

| Produção | Laboratório | Motivo |
|---|---|---|
| 172.17.4.0/24 | 172.30.4.0/24 | 172.17.0.0/16 é a rede padrão do Docker e 172.18.0.0/16 já está em uso por outro projeto |
| 200.159.177.x | 172.30.177.x (mesmos finais) | Rede "pública" simulada |
| VIP 172.17.4.100 | VIP 172.30.4.100 | — |

Como na VM do Parallels, a `vm-teste` fica só na rede "pública" e **não alcança o VIP**.
Para testar o sysbench, ligue-a à rede interna com `./lab.sh interna`.

Todos os servidores têm o sshd e os usuários `loadtest` e `admin` (com sudo), com
senhas aleatórias geradas no `.env`. O `loadtest` pode rodar `fs_cli` e
`opensips-cli` com `sudo -n`, como no sudoers sugerido para a produção.

## O que é real e o que é simulado

| Componente | Situação |
|---|---|
| Debian 12, sshd, sudo, `/proc` | Real |
| Percona XtraDB Cluster 8.4.10 (2 nós, SST, quórum) + keepalived | Real. Diferença: `pxc-encrypt-cluster-traffic=OFF` |
| nginx 1.22.1, PHP-FPM 7.3.33 (`stub_status`, `/fpm-status`) | Real |
| Sessão do CodeIgniter | Simulada pela `index.php`: grava em `flux.ci_sessions` como o CI |
| OpenSIPS e FreeSWITCH | **Simulados** com SIPp (processos com o nome `opensips` e `freeswitch`). Atendem como a caixa postal; não há `load_balancer`, dialplan nem RTP de volta |
| `fs_cli` / `opensips-cli` | Simulados. O `fs_cli` exige a senha do event socket; os números (chamadas, sessões) vêm do SIPp |

O laboratório serve para validar o script (chaves SSH, coleta, limites, relatório,
cluster, VIP, sessão web), não para medir a capacidade de VoIP.

## Uso

Requisitos: Docker Desktop em execução, com pelo menos 4 GB de memória para ele.

```bash
cd misc/loadtest/lab
```

```bash
./lab.sh up
```

O `up` gera o `.env` com senhas aleatórias, constrói as imagens (a primeira vez baixa
os pacotes e leva alguns minutos), sobe os containers, espera o cluster formar e gera
a configuração em `out/` (montada na `vm-teste` como `/etc/flux-loadtest`).

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
| `up` | Gera o `.env`, constrói, sobe, espera o cluster e gera `out/loadtest.conf`. Os servidores geram chaves de host novas a cada subida, então o `known_hosts` do laboratório é zerado |
| `keys` | Roda o `keys setup` na `vm-teste` respondendo, com `expect`, a senha do `loadtest` em cada servidor (só no laboratório) |
| `conf [--dids ARQ]` | Regenera `out/loadtest.conf`, `out/dids.txt` e os arquivos de senha. Sem `--dids`, gera 100 mil DIDs fictícios; com `--dids`, aceita uma lista simples ou o CSV `id;number;...` |
| `status` | Estado dos containers, do cluster (tamanho, Primary, Synced), do VIP e quantidade de linhas em `flux.ci_sessions` |
| `shell` | Shell na `vm-teste` |
| `interna` / `externa` | Liga/desliga a `vm-teste` da rede interna (para `--tests mysql`) |
| `down` | Remove containers e redes; os dados do laboratório são efêmeros |

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

## DIDs

O padrão são 100 mil DIDs fictícios (`5551900000000` a `5551900099999`), porque o SIP é
simulado e qualquer número serve. A lista real de DIDs ativos pode ser usada aqui
(`./lab.sh conf --dids ARQUIVO`) para testar o volume, mas **não deve ser usada como
`DID_FILE` em produção**: os DIDs ativos encaminham para PBXs e números de clientes,
e o teste geraria chamadas reais.
