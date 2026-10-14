# Laboratório STFC em Docker

Réplica do ambiente STFC para validar o `flux-loadtest` sem tocar na produção. Seis
containers Debian 12 com os mesmos nomes, papéis e finais de IP dos servidores reais:
OpenSIPS 3.6 e FreeSWITCH 1.11.3 reais com os scripts do Flux (PHP do `xml_curl`, Lua do
dialplan, schema do banco), Percona XtraDB Cluster 8.4.10, nginx + PHP-FPM 7.3 e a VM de
teste. Um Zabbix 7.2.3 (mesma versão da produção) recebe as amostras dos testes. Pelo macOS dá para acessar a
interface web, o Zabbix e o SSH dos servidores, e registrar SIP devices (softphones).

## Topologia

| Container (hostname) | Rede interna 172.30.4.0/24 | Rede "pública" 172.30.177.0/24 | O que roda |
|---|---|---|---|
| `sbc-stfc-1` | .163 | .163 | OpenSIPS 3.6.9 (5060, 5065 e 5062 para o macOS) + FreeSWITCH 1.11.3 (perfil `default` 5070 no IP público, como em produção; `lab-mac` 5080 no interno) |
| `sbc-stfc-02` | .162 | .162 | FreeSWITCH 1.11.3 (perfis `default` 5070 e `lab-mac` 5080) |
| `banco-master-sbc-stfc` | .161 | .161 | Percona XtraDB Cluster 8.4.10-10 + keepalived (VIP .100, prioridade 150) |
| `banco-slave-stfc` | .164 | .164 | Percona XtraDB Cluster 8.4.10-10 + keepalived (prioridade 100) |
| `sbc-stfc-interfaceweb` | .165 | .165 | nginx 1.22.1 + PHP-FPM 7.3.33; página PHP com sessão no banco pelo VIP |
| `vm-teste` | — | .50 | VM originadora: SIPp (originador e atendedor em 5090), wrk, sysbench; o repositório montado em `/opt/flux-loadtest` |
| `zabbix-server` | — (zbx .10) | .10 | Zabbix server 7.2.3, como em produção (trapper 10051) |
| `zabbix-web` | — (zbx .11) | .11 | Frontend e API do Zabbix (8080) |
| `zabbix-db` | — (zbx .5) | — | PostgreSQL 16 do Zabbix; dados no volume `flux-stfc-lab_zbx-db-<versão do Zabbix>-pg<versão do PG>` |

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

## Requisitos do SBC real

| Item | Onde | Padrão |
|---|---|---|
| Token da SignalWire (pacotes do FreeSWITCH, como o `FS_TOKEN` do `flux_install.sh`) | arquivo 0600 fora do repositório; `LAB_SIGNALWIRE_TOKEN_FILE` no `.env` | `~/.config/flux-lab/signalwire.token` |
| Clone do repositório `sbc` (schema, migrações, PHP do `xml_curl`, `autoload_configs`, `vars.xml`) | `LAB_FLUX_SRC` no `.env`, montado só leitura em `/opt/flux-src` | `~/Desenvolvedor/Flux/Repositorio/dpxdan/sbc` |
| Scripts Lua do dialplan (diretório `scripts` do FreeSWITCH) | `LAB_FLUX_SCRIPTS` no `.env`, montado só leitura em `/opt/flux-scripts`; sem `flux/flux.lua`, usa os do clone | snapshot de produção `~/Desenvolvedor/Flux/Servidores/flux-sbcbr/sbc01/freeswitch/scripts` |

O token entra só no build, como secret do BuildKit: o `auth.conf` do apt é criado e
apagado no mesmo passo e nenhuma camada da imagem o guarda. Para voltar ao SBC
simulado com SIPp (sem token e sem o repositório `sbc`), use `LAB_SBC_TARGET=sbc` no `.env`.

Na primeira subida, o `lab.sh flux` carrega no cluster o schema do Flux como o
`install_database` do instalador (`flux-6.4.sql`, `flux-tables.sql`, `flux-6.4.1.sql`,
`flux-views.sql`, ring group, português e as migrações de `database/updates` em ordem de
data, com `-f`). Depois grava, sempre:

| Dado | Valor |
|---|---|
| `fluxuser` | `172.30.%`, `127.0.0.1` e `localhost` (os triggers usam `DEFINER fluxuser@127.0.0.1`), senha `LAB_FLUX_DB_PASSWORD` |
| `system` | `opensips = 0` e `opensips_domain = 172.30.177.163` (IP público do OpenSIPS) no grupo `opensips` (ACL `default` e `event` do FreeSWITCH) |
| Conta de teste | id 2 do schema (`4727985745`): sem limite de canais e com limite de crédito alto |
| Ramais | `LAB_SIP_DEVICES` (padrão 20) a partir de 1000, senhas aleatórias em `out/sip_devices.csv` |
| DIDs | `LAB_DIDS` (padrão 100 mil) `55519xxxxxxxx` DIRECT-IP (`call_type = 2`) -> atendedor da vm-teste `172.30.177.50:5090`; um DID `5511300` + ramal (DID local) por ramal do macOS |
| Perfis SIP | `default` na porta 5070 do IP público (`$${pub_ip_v4}`, definido pelo `start.sh`); `lab-mac` (cópia do `default` no IP interno `$${local_ip_v4}`, porta 5080, `ext-rtp-ip` 127.0.0.1) |
| OpenSIPS (criado pelo `sbc-stfc-1`) | tabelas do pacote `opensips-mysql-dbschema`; `address` grupo 10 = vm-teste, grupo 20 = FS (IPs públicos e internos); `load_balancer` grupo 1 -> FS 172.30.177.x:5070 com `channels=fs://...@172.30.177.x:8021`; `dispatcher` setid 2 -> FS 172.30.4.x:5080 |
| `loadtest.conf` | `UAS_PORT=5090`: o `flux-loadtest` sobe o atendedor na vm-teste durante a fase `sip` |

## SIP devices no macOS

```bash
./lab.sh devices
```

Configuração do softphone (Zoiper, Linphone, MicroSIP...):

| Campo | Valor |
|---|---|
| Servidor / domínio | `127.0.0.1`, porta `5060` (`LAB_PORT_SIP`), UDP |
| Usuário e usuário de autenticação | `1000` a `1019` |
| Senha | coluna `senha` do `./lab.sh devices` |
| Codecs | PCMA, PCMU |

Caminho do REGISTER, igual ao de produção a partir do OpenSIPS:

```
softphone -> 127.0.0.1:5060 -> OpenSIPS :5062 (anuncia 127.0.0.1:5060) -> mid_registrar
         -> dispatcher setid 2 (hash do usuário) -> FreeSWITCH :5080 (perfil lab-mac)
         -> PHP xml_curl (sip_devices) -> desafio digest -> 200 OK
```

- **Socket 5062 `as 127.0.0.1:5060`:** Via, Record-Route e Contact apontam para um
  endereço que o Mac alcança. A vm-teste continua usando o 5060 do IP "público".
- **Perfil `lab-mac`:** anuncia o RTP em 127.0.0.1. As faixas de RTP de cada FreeSWITCH
  são publicadas 1:1 no Mac (`LAB_RTP1_*` 16384-16583 e `LAB_RTP2_*` 16584-16783), o que
  limita o laboratório a cerca de 100 chamadas com mídia por nó.
- **Ramal registrado em um nó só:** o dispatcher fixa o ramal num FreeSWITCH (hash do
  usuário), como em produção. Uma chamada que caia no outro nó não encontra o registro.

Teste de registro sem softphone, com o SIPp do Mac (REGISTER, digest, 15 s registrado,
`Expires: 0`):

```bash
sipp -sf lab/sip/register.xml -inf lab/out/sip_devices.sipp.csv -m 1 -i 127.0.0.1 127.0.0.1:5060
```

Conferir o registro:

```bash
docker compose -p flux-stfc-lab exec sbc-stfc-1 opensips-cli -x mi ul_dump
```

## Acesso pelo macOS

O Docker Desktop não roteia do Mac para os IPs dos containers: as portas abaixo são
publicadas só em `127.0.0.1` e podem ser trocadas no `.env` (`LAB_PORT_*`). O
`./lab.sh status` mostra a lista atual.

| Serviço | Endereço no Mac | Variável |
|---|---|---|
| Interface web (nginx + PHP-FPM) | `https://127.0.0.1:8443/` (certificado autoassinado), `http://127.0.0.1:8081/` | `LAB_PORT_WEB_HTTPS`, `LAB_PORT_WEB_HTTP` |
| Zabbix (frontend e API) | `http://127.0.0.1:8080/` (usuário `Admin`, senha em `out/zabbix_admin.pass`) | `LAB_PORT_ZABBIX_WEB` |
| Zabbix trapper | `127.0.0.1:10051` | `LAB_PORT_ZABBIX_TRAPPER` |
| SIP devices | `127.0.0.1:5060/udp` | `LAB_PORT_SIP` |
| RTP do FreeSWITCH | `127.0.0.1:16384-16783/udp` | `LAB_RTP1_START`..`LAB_RTP2_END` |
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

O histórico fica no volume `flux-stfc-lab_zbx-db-7.2.3-pg16` (um por versão do Zabbix e
do PostgreSQL, porque nenhum dos dois volta de versão) e sobrevive ao `down`; para
apagar, use `./lab.sh down --zabbix`. O volume `flux-stfc-lab_zbx-db`, do Zabbix 7.4.15
usado antes, fica sem uso: confira com `docker volume ls` e remova quando não precisar
mais do histórico.

## O que é real e o que é simulado

| Componente | Situação |
|---|---|
| Debian 12, sshd, sudo, `/proc` | Real |
| Percona XtraDB Cluster 8.4.10 (2 nós, SST, quórum) + keepalived | Real. Diferença: `pxc-encrypt-cluster-traffic=OFF` |
| nginx 1.22.1, PHP-FPM 7.3.33 (`stub_status`, `/fpm-status`) | Real |
| Sessão do CodeIgniter | Simulada pela `index.php`: grava em `flux.ci_sessions` como o CI |
| OpenSIPS 3.6.9 | Real, com o `opensips.cfg` de produção (`sbc01`): `mid_registrar`, `load_balancer` com estatísticas do FreeSWITCH, `dispatcher`, `permissions`, `tracer` |
| FreeSWITCH 1.11.3 | Real (pacotes SignalWire), com `autoload_configs`, `vars.xml`, PHP do `xml_curl` e Lua do dialplan do repositório `sbc` |
| `fs_cli` / `opensips-cli` | Reais |
| SBC simulado (`LAB_SBC_TARGET=sbc`) | SIPp com os nomes `opensips` e `freeswitch`, `fs_cli` e `opensips-cli` simulados (versão anterior do laboratório) |

### Diferenças do SBC real em relação a produção

| Item | Laboratório | Motivo |
|---|---|---|
| Perfil `lab-mac` (5080) e socket 5062 do OpenSIPS | Só no laboratório | Mídia e sinalização alcançáveis pelo macOS (Docker Desktop não roteia para os IPs dos containers) |
| Atendedor na vm-teste (5090) | DIDs do teste DIRECT-IP para a própria VM originadora | Em produção, a mesma configuração (seção 6.6 do README), com o IP público da VM |
| `dispatcher` setid 2 | Aponta para o 5080 | Registros dos devices no perfil `lab-mac` |
| `system.opensips*` | Grupo `opensips` | No schema 6.4 estão em `signup`, e o PHP só lê `global`, `opensips`...; sem isso a ACL não libera o OpenSIPS. Conferir na base de produção |
| `pxc_strict_mode` | `PERMISSIVE`, `sql_mode=""` | Seis tabelas do Flux (`cdrs`, `cdrs_staging`, `reseller_cdrs`...) não têm chave primária e o modo `ENFORCING` recusa gravar nelas. Conferir no PXC de produção |
| Driver ODBC | MariaDB (`odbc-mariadb`) | O instalador copia o `libmyodbc8` de um pacote local |
| `mod_bcg729`, `mod_h26x` | Fora do `modules.conf.xml` | Sem pacote para bookworm no repositório SignalWire (codecs, sem efeito no teste) |
| OpenSIPS | 3.6.9 | Versão atual do repositório 3.6 (produção: 3.6.8) |
| Event socket | `0.0.0.0` com ACL `event` | O container não tem IPv6 |
| Logs | `/var/log/opensips.log`, `/var/log/freeswitch/freeswitch.log` | Sem syslog no container |
| Zabbix 7.2.3 (imagens oficiais `ubuntu-7.2.3`, `LAB_ZABBIX_VERSION`) + PostgreSQL 16 (`LAB_ZBX_PG_VERSION`) | Real. PostgreSQL 16 porque o `psql` das imagens 7.2.x não lista bancos no 17 (coluna `daticulocale`) e o entrypoint fica esperando o banco |

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

- **CPU compartilhada:** os containers dividem as vCPUs da VM do Docker Desktop (2
  por padrão) e todos leem o mesmo `/proc/stat`: a CPU de cada "servidor" no relatório
  é a da VM do Docker. Com RTP nas duas pernas, 4 vCPU saturam por volta de 100
  chamadas simultâneas. Sob carga web, todos os "servidores" chegam a ~99% de CPU juntos, o
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

## Validação do SBC real (2026-10-14)

| Teste | Resultado |
|---|---|
| Build com o token como secret | FreeSWITCH 1.11.3, OpenSIPS 3.6.9, PHP 7.3.33, ODBC MariaDB; nenhum `auth.conf` na imagem |
| Schema do Flux | 158 tabelas, sem erros; 100 mil DIDs e 20 ramais gravados |
| FreeSWITCH | Perfis `default` e `lab-mac` gerados pelo PHP a partir de `sip_profiles`; ACL `default`/`event` com o OpenSIPS |
| OpenSIPS | `load_balancer` com `max` vindo do event socket dos dois FS; `dispatcher` com os dois nós ativos |
| REGISTER do macOS (SIPp, ramal 1000) | 401 -> digest -> 200 OK; contato no `ul_dump` do OpenSIPS e `Registered(AUTO-NAT)` no FS escolhido pelo hash |
| `check` do flux-loadtest | `fs_cli` e `opensips-cli` reais respondendo |
| Chamada para DID local de ramal não registrado, scripts do `sbc01` | Passa por OpenSIPS -> `load_balancer` -> FS -> dialplan Lua (DID local, conta 2); termina em **480** (ver abaixo) |
| DID local de ramal registrado (ramal 1000 pelo macOS, 5 chamadas) | Só chega ao device quando o `load_balancer` escolhe o FS do registro: 1 de 5; as 4 que caíram no outro FS terminaram em `USER_NOT_REGISTERED` (ver abaixo) |
| `smoke` para DID DIRECT-IP com atendedor | 1/1; 1 chamada recebida pelo atendedor; INVITE -> 200 em 148 ms. Mídia pelo FS nas duas pernas (`mediaStats`: originador :20000 e atendedor :40000 recebendo e enviando G.711) |
| `run -t sip -r 3 -H 15 -w 45` com atendedor | 102/102 no originador e no atendedor, sem falhas; pico de 50 simultâneas; INVITE -> 200 em 129 ms; Zabbix: `flt.uas` e `flt.result[uas_*]` recebidos (359 valores, nenhum recusado) |
| `run -t sip -r 10 -H 20 -w 60` com atendedor | Interrompido pelo guard (CPU ~95% em todos os "servidores": é a VM do Docker inteira, 4 vCPU); 168 chamadas atendidas sem falha no atendedor; 13 falhas no originador (480/502) com a CPU saturada |

**DID para ramal não registrado não cai na caixa postal.** Nos scripts do `sbc01`
(15/09) e do fork, o XML gerado para DID local (`custom_inbound_0` em
`lib/addons/sip_routing.lua`) tem, nesta ordem: `bridge` para o ramal, `lua
flux-sipdevice-routing.lua` (failover) e `leave_voicemail`. O
`flux-sipdevice-routing.lua` (igual nos dois) chama `session:hangup()` sempre que o
bridge não termina em `SUCCESS`, então o `leave_voicemail` nunca executa: o chamador
recebe 480 (`USER_NOT_REGISTERED`). A premissa da seção 6.6 do README (ramal não
registrado com `vm-enabled` atende pela caixa postal) não vale para esses scripts.

**DID para ramal registrado depende do nó.** O REGISTER do device passa pelo
`dispatcher` (setid 2, hash do usuário) e fica em um FS só; as chamadas de operadora
passam pelo `load_balancer` (grupo 1), que escolhe o FS pela carga, sem saber onde o
ramal registrou. No outro FS, o `bridge user/RAMAL@dominio` termina em
`USER_NOT_REGISTERED`. Como o laboratório usa o mesmo `opensips.cfg` e os mesmos scripts,
o comportamento deve se repetir em produção.

Por isso o teste de carga usa DIDs DIRECT-IP para o atendedor da vm-teste (seção 6.6 do
README): o caminho não depende de registro nem de caixa postal.

## Validação do Zabbix (2026-10-14)

| Teste | Resultado |
|---|---|
| `up` com Zabbix 7.4.15 | Senha do Admin trocada, token criado, 7 templates importados, 8 hosts `lab-*`; segundo `up` só atualiza (idempotente) |
| Zabbix 7.2.3 (versão de produção), YAML no formato 7.2 | Bootstrap, import dos 7 templates e 8 hosts; 43 gatilhos e nenhum item não suportado; importação de execução antiga (359 valores) e `run` ao vivo com o atendedor (359 valores, nenhum recusado; `flt.uas[received_c]` = 102) |
| `zabbix send` de execuções de 07/10 | 853 e 319 valores, nenhum recusado; reenvio bloqueado sem `--force` |
| `run -t sip,web -r 10 -H 10 -w 60` com envio ao vivo | 491 valores, nenhum recusado; itens dependentes sem erro; `flt.result[status]` = `ok`, 220 chamadas, pico de 71 simultâneas |
| Gatilhos | "Execução interrompida" abre com a importação do failover e fecha com a execução `ok`; watchdog do SIPp e descarte UDP disparam e se recuperam |
| Acesso pelo macOS | Zabbix (8080), interface web (8443/8081), trapper (10051) e SSH (22161-22165) respondem em 127.0.0.1 |

## DIDs

O padrão são 100 mil DIDs fictícios (`5551900000000` a `5551900099999`), DIRECT-IP
para o atendedor da vm-teste. A lista real de DIDs ativos pode ser usada aqui
(`./lab.sh conf --dids ARQUIVO`) para testar o volume, mas **não deve ser usada como
`DID_FILE` em produção**: os DIDs ativos encaminham para PBXs e números de clientes,
e o teste geraria chamadas reais.
