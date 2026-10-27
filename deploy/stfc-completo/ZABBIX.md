# Resultados do teste de carga do STFC no Zabbix

Roteiro para exibir os resultados do flux-loadtest no Zabbix que já existe, com o gerador no
`sbc-stfc-interfaceweb` (.165):

1. hosts, templates e o dashboard **Flux Loadtest - Resultados** (`zabbix setup`);
2. importação das execuções de 21/10/2026 (`zabbix send`);
3. envio ao vivo nos próximos testes (`ZABBIX_SERVER`);
4. `zabbix-agent` no .165 para iniciar e parar perfis pelo menu do Zabbix.

Detalhes de cada peça em `docs/configuracao/zabbix.md` (documentação MkDocs).

## O dashboard

Criado ou atualizado pelo `zabbix setup` (idempotente), com o nome
`Flux Loadtest - Resultados (<prefixo>)`:

| Página | Widgets |
|---|---|
| Resultados | Tabela com uma linha por execução: execução, status, chamadas criadas, falhas (%), pico de simultâneas, pico de CPS, INVITE -> 200 médio, originadas que não chegaram ao atendedor, motivo da interrupção. Gráficos de CPS alvo e realizado, simultâneas (originador e atendedor), INVITE -> 100/200 e falhas/retransmissões por período. Problemas do grupo `Flux Loadtest` |
| Gargalos | Problemas do teste com as tags `componente` e `tipo` (incluindo os suprimidos pela manutenção). Gráficos de carga contra sintoma: INVITE -> 200 x simultâneas, tempo de resposta do FS x sessões, thread mais carregada de cada processo, ocupação do OpenSIPS e do `load_balancer`, latência e fila do MySQL, descartes de rede, CPU por núcleo |
| Servidores | CPU e memória por servidor, sessões e chamadas dos FreeSWITCH, memória compartilhada, diálogos e transações do OpenSIPS, consultas e CPU do MySQL, pacotes recebidos |

Os gráficos usam padrão de host e de nome de item (`flt-*`, `flt-fs*`...): servidores novos
entram sozinhos. Para ver uma execução antiga, escolha o período dela no seletor de tempo do
dashboard (as de 21/10/2026: das 20:35 às 23:58).

Validado num Zabbix 7.2.3 com a importação das 8 execuções de 21/10/2026: a tabela trouxe os
mesmos números dos `report.txt` (ex.: `stfc-meta-c2000`, 2122 criadas, 7,3% de falha, pico de
1962 simultâneas, INVITE -> 200 de 140 ms).

### Onde está o gargalo

A página **Gargalos** do dashboard junta, para o período escolhido, os problemas do teste e um
gráfico de carga contra sintoma por componente. Os problemas trazem duas tags:

- `tipo=sintoma`: o efeito visto pelo SIPp (atendimento lento, retransmissões, falhas);
- `tipo=gargalo`: o recurso que está no limite, com `componente` = `freeswitch`, `opensips`,
  `mysql`, `rede`, `cpu`, `memoria`, `disco`, `web` ou `gerador`.

O widget de problemas mostra também os suprimidos: os hosts `flt-*` ficam numa manutenção com
coleta (seção 6) e, sem isso, nada apareceria.

Como ler um sintoma (o gatilho "Atendimento lento: INVITE -> 200 acima de 1000 ms"):

| O que sobe junto com o INVITE -> 200 | Gargalo provável | Onde confirmar |
|---|---|---|
| `FreeSWITCH: handles do banco em uso` perto de 100% do `max-db-handles`, ou `show calls count` alto com `status` rápido e `MySQL: latencia media` baixa | Pool de conexões do FS (`max-db-handles`, `db-handle-timeout`) | `fs_cli -x 'db_cache status'` e conexões por origem no banco. O aviso `Max handles ... exceeded` não aparece no log com `loglevel` DISABLE |
| `FreeSWITCH: tempo do show calls count` e `MySQL: latencia media` altos | Banco (core db ou consultas do dialplan) | `MySQL: consultas executando`, flow control, consultas lentas |
| `FreeSWITCH: thread mais carregada` perto de 100 com a CPU total baixa | Uma thread do FS, como o loop do sofia-sip da SIP-387 | `sip387-diagnostico.sh` no FS durante o patamar |
| `FreeSWITCH: tempo de resposta do fs_cli` alto e CPU ociosa baixa | CPU do FS | `CPU total`, `FreeSWITCH: CPU ociosa` |
| `OpenSIPS: load` alto ou `OpenSIPS: thread mais carregada` perto de 100 | Workers do OpenSIPS (`children`/`udp_workers`) ou algo lento no script | `OpenSIPS: transacoes em uso` |
| `OpenSIPS: destino do load_balancer mais cheio` perto de 100 | Capacidade do `load_balancer` (o FS ainda tem folga) | `lb_list`, `fs-limites.sh mostrar` |
| `Erros de buffer de recepcao UDP` ou `Descartes na interface` acima de 0 | Rede ou buffer do kernel | `net.core.rmem_max`, softirq no `CPU do nucleo mais carregado` |
| `SIPp: thread mais carregada` perto de 100 | Gerador: os números deixam de medir os servidores | CPU do .165 |
| Nenhum dos acima | Atraso fora do que o coletor mede | Captura no .165 e `pdd-pcap.py` (atraso por FS e por trecho) |

Limites (macros dos templates, ajustáveis por host):

| Macro | Padrão | Gatilho |
|---|---|---|
| `{$FLT.SIP.PDD.MAX}` | 1000 ms | INVITE -> 200 médio do período |
| `{$FLT.SIP.RETRANS.MAX}` | 20 | Retransmissões por período do SIPp |
| `{$FLT.FS.PROBE.MAX}` | 500 ms | `status` e `show calls count` do FS |
| `{$FLT.FS.SESSIONS.PCT}` | 90% | Sessões / `max_sessions` em uso |
| `{$FLT.FS.DBH.PCT}` | 80% | Handles do core db em uso (`db_cache status`) / `max-db-handles` |
| `{$FLT.THREAD.MAX}` | 85% | Thread mais carregada (FS, OpenSIPS, MySQL, SIPp) |
| `{$FLT.OS.LOAD.MAX}` | 70% | `load:load` dos workers do OpenSIPS |
| `{$FLT.OS.LB.MAX}` | 85% | Destino mais cheio do `load_balancer` |
| `{$FLT.DB.LAT.MAX}` | 20 ms | Latência média das consultas (performance_schema) |
| `{$FLT.DB.RUNNING.MAX}` | 8 | `Threads_running`: ajuste para o número de núcleos do banco |
| `{$FLT.DB.CONN.MAX}` | 80% | Conexões / `max_connections` |
| `{$FLT.IOWAIT.MAX}` | 20% | CPU esperando disco |
| `{$FLT.NET.DROP.MAX}` | 0 | Descartes por segundo na interface |

Os gatilhos de contador (descartes do OpenSIPS, diálogos com falha, locks e consultas lentas
do MySQL) disparam quando o contador sobe entre duas amostras.

Para aplicar (no .165, depois de atualizar o repositório):

```bash
cd /opt/flux-loadtest && git pull --ff-only
./flux-loadtest.sh zabbix setup --import-template -c /etc/flux-loadtest/loadtest.conf
```

O `--import-template` atualiza os templates e o `setup` refaz o dashboard. Os coletores novos
entram na próxima execução; as execuções antigas não têm as métricas novas.

A latência média do MySQL precisa de `SELECT` no `performance_schema` para o usuário do
`MYSQL_CLI_CMD`. Sem a permissão, o item fica vazio e o gatilho não dispara:

```sql
GRANT SELECT ON performance_schema.* TO 'USUARIO_DO_FLUX_LOADTEST'@'HOST';
```

## Pré-requisitos

| Item | Detalhe |
|---|---|
| Zabbix | 7.2 (o template é gerado para o 7.2; entra também num 7.4) |
| Usuário da API | Escrita em hosts e templates **e permissão para criar dashboards** (ex.: um usuário do tipo Admin). Token em *Users > API tokens* |
| Trapper | O .165 alcança o server (ou um proxy) na porta **10051/TCP**. O trapper não tem criptografia: só em rede interna |
| Agent (passo 5) | O server (ou proxy) alcança o .165 na porta **10050/TCP** |

Antes de alterar o firewall do .165 ou do Zabbix, confirme o impacto: são duas regras de
entrada/saída restritas aos IPs do Zabbix e do .165, sem efeito no tráfego SIP.

## 1. Configuração no .165

Atualize o repositório (o `zabbix setup` novo cria o dashboard):

```bash
cd /opt/flux-loadtest && git pull --ff-only && git log --oneline -1
```

Token da API num arquivo 0600 (cole o token quando o `read` pedir; ele não aparece na tela):

```bash
install -m 0600 /dev/null /etc/flux-loadtest/zabbix_api.token && read -rs -p 'Token da API do Zabbix: ' T && printf '%s\n' "$T" > /etc/flux-loadtest/zabbix_api.token && unset T && echo && wc -c /etc/flux-loadtest/zabbix_api.token
```

O arquivo deve ter 65 bytes (64 hexadecimais mais a quebra de linha).

Em `/etc/flux-loadtest/loadtest.conf`, preencha (troque `IP_DO_ZABBIX` e a URL):

```
ZABBIX_SERVER=IP_DO_ZABBIX
ZABBIX_PORT=10051
ZABBIX_HOST_PREFIX=flt-
ZABBIX_LIVE=1
ZABBIX_API_URL=https://ENDERECO_DO_ZABBIX/api_jsonrpc.php
ZABBIX_API_TOKEN_FILE=/etc/flux-loadtest/zabbix_api.token
ZABBIX_TLS_INSECURE=0
```

`ZABBIX_TLS_INSECURE=1` só se a interface usar certificado autoassinado.

## 2. Hosts, templates e dashboard

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix setup --import-template -c /etc/flux-loadtest/loadtest.conf
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix check -c /etc/flux-loadtest/loadtest.conf
```

Esperado: `dashboard criado: Flux Loadtest - Resultados (flt-)` no `setup` e
`trapper ...: ok (processados 1, recusados 0)` no `check`. Se o `setup` disser
`AVISO: dashboard nao criado`, os hosts estão prontos e falta permissão de dashboard ao usuário
do token.

## 3. Importar as execuções de 21/10/2026

Cada execução é enviada uma vez, com os horários originais (a marca `zabbix.sent` evita
duplicar):

```bash
cd /opt/flux-loadtest && for d in /var/lib/flux-loadtest/results/20261021-*-stfc-*/; do echo "== ${d}"; ./flux-loadtest.sh zabbix send "${d%/}" -c /etc/flux-loadtest/loadtest.conf; done
```

Cada linha deve terminar em `recusados 0`. Depois, no Zabbix: *Dashboards >
Flux Loadtest - Resultados (flt-)*, período de 21/10/2026 20:35 a 23:58.

O resultado de cada execução (identificador, status, totais e INVITE -> 200 médio) é montado
na importação, a partir do `run.env`, do `abort.txt` e do `sip/stats.csv` de cada diretório.

## 4. Envio ao vivo

Com `ZABBIX_SERVER` e `ZABBIX_LIVE=1`, todo `run` passa a aparecer no Zabbix enquanto roda.
Nada muda no comando. Se o Zabbix cair, o teste continua e os valores ficam na fila
(`zabbix.log` no diretório da execução).

## 5. Agent no .165: iniciar e parar perfis pelo Zabbix

**Impacto no .165 (produção):**
- instala o pacote `zabbix-agent` 7.2 do repositório oficial do Zabbix, se faltar, e abre o
  serviço na porta 10050, aceitando só o `Server=` informado;
- se o .165 já tiver o `zabbix-agent` (servidor já monitorado), o `zabbix_agentd.conf` não é
  alterado e o `--zabbix-server` é ignorado: só entra o include do flux-loadtest, no diretório
  do `Include=` do agent. No .165 (agent 6.0.14 do Debian, `Server=200.159.177.242`):
  `/etc/zabbix/zabbix_agentd.conf.d/flux-loadtest.conf`, ao lado do
  `userparameter_fluxsbc.conf`. O `DenyKey=system.run[*]` não muda nada no que existe: o 6.0
  já bloqueia `system.run` por padrão, e o host não usa `system.run` nem comando remoto;
- o restart do `zabbix-agent` deixa o .165 alguns segundos sem coleta;
- instala `/usr/local/sbin/flux-loadtest-zbx`, `/etc/sudoers.d/flux-loadtest-zbx` (o usuário
  `zabbix` roda só esse wrapper) e o include do agent, que libera apenas os comandos exatos de
  cada perfil;
- quem tiver permissão de executar os scripts no Zabbix dispara carga nos servidores reais. Use
  `ZABBIX_SCRIPT_USRGRP` para restringir a um grupo.

Perfis do STFC (deste diretório):

| Perfil | Carga |
|---|---|
| `stfc-piloto` | 10 CPS por 60 s |
| `stfc-cps20` | 20 CPS sustentados por ~3 min (o maior valor com atraso aceitável hoje) |
| `stfc-cps30` | 30 CPS sustentados por ~220 s (hold de 30 s): banco, `sps` e o A1; exige `fs-limites 150 1300` |
| `stfc-c1000` | 1000 simultâneas a 10 CPS |
| `stfc-c3000` | 3000 simultâneas a 10 CPS (hold de 300 s); exige limites maiores nos FS |
| `stfc-c5000` | 5000 simultâneas a 10 CPS (hold de 500 s); exige limites maiores nos FS |

O wrapper recusa CPS acima de 50 e janela acima de 3600 s
(`/etc/flux-loadtest/zabbix-runner.conf`; exemplo em `profiles/zabbix-runner.conf.example`).

### Perfis de 3000 e 5000 simultâneas

Os dois mantêm os 10 CPS do `stfc-c1000` e só aumentam o hold, para medir chamadas simultâneas
sem misturar com o atraso de CPS do .162 (A1). Simultâneas em regime = CPS x hold.

| Perfil | Janela / hold | Patamar | Duração total | `-l` do sipp | `fs-limites.sh aplicar` (nos 2 FS) |
|---|---|---|---|---|---|
| `stfc-c3000` | 420 s / 300 s | 120 s em 3000 | ~16 min | 3648 | `150 4200` |
| `stfc-c5000` | 620 s / 500 s | 120 s em 5000 | ~23 min | 6048 | `150 7000` |

Regra do `max-sessions`: **1,4 x simultâneas**. Cada chamada ocupa 2 sessões, e o
`load_balancer` não divide meio a meio: manda até ~55% para o .162, que tem mais CPU ociosa por
não dividir o servidor com o OpenSIPS. Em 27/10/2026, com 3500, o .162 chegou a 91,6% no
`stfc-c3000` e, com 5500, a 96% no `stfc-c5000`. O fator 1,4 deixa o nó mais carregado em ~80%,
com folga para o tráfego real. Quando o FS chega ao `max-sessions`, ele responde
`503 Maximum Calls In Progress` **também para as chamadas reais**, até o guard parar o teste.

O `max` do `lb_list` não é fixo: o OpenSIPS o recalcula com os dados que o FS publica (sessões e
CPU ociosa). Nas fotos de 27/10/2026, sem carga, ficou perto de `max_sessions` x CPU ociosa; no
pico do `stfc-c3000` caiu para ~1700-1900, e a ocupação do destino mais cheio chegou a 90,9%.

O `switch.conf.xml` dos dois FS foi alterado para `max-sessions` 5000 e `sessions-per-second`
300 depois da campanha de 21/10 (que mediu 2000 por FS). O arquivo só vale depois de um restart,
então confira o valor em uso antes de cada perfil:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh mostrar
```

| `max_sessions` em uso | `stfc-c3000` | `stfc-c5000` |
|---|---|---|
| 5000 | cabe; o `aplicar 150 4200` mantém 5000 | **não cabe**: ~5500 no .162 + o tráfego real; aplicar `150 7000` |
| 2000 ou 3500 | aplicar `150 4200` | aplicar `150 7000` |

O mesmo arquivo traz três itens que valem para os dois perfis:
- `core-db-dsn` no MySQL (DSN `FLUX`, cluster PXC): a tabela `channels` de cada FS passa a ter
  milhares de linhas e cada chamada gera escritas no cluster. O volume de escritas acompanha o
  CPS (10, como no `stfc-c1000`), mas acompanhe o flow control do PXC no dashboard.
- `max-db-handles` 50 e `db-handle-timeout` 10: se o pool esgotar, a criação de canal espera
  até 10 s. O coletor lê o pool com `db_cache status` a cada amostra
  (`FreeSWITCH: handles do banco em uso`, gatilho em `{$FLT.FS.DBH.PCT}`).
- `loglevel`: em 27/10/2026 estava em DISABLE nos dois FS (`fsctl loglevel`). Bom para o
  desempenho, mas nenhum aviso do FS chega ao log, nem o de pool esgotado: use as métricas do
  coletor. Com `loglevel` debug, o volume de log acompanha o CPS e o disco cai mais rápido.

**Antes do `stfc-c3000`:**

```bash
# nos dois FS (.163 e .162)
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh aplicar 150 4200
# no .163, ~30 s depois: o max dos dois nos precisa ter subido
opensips-cli -x mi lb_list | grep -E '"(uri|max|load)"'
```

**Antes do `stfc-c5000`**, só depois de um `stfc-c3000` sem falhas, aplicar `150 7000` e
conferir nos dois FS, porque o .162 chega a ~5500 sessões. A ação `capacidade` do
`flux-loadtest.sh` (`docs/execucao/comandos.md`, `capacidade`) faz todas as conferências abaixo de uma vez, sem
carga, e alerta o que estiver perto do limite ou com timeout de mídia menor que o hold:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh capacidade -c /etc/flux-loadtest/loadtest.conf --hold 500 --label antes-c5000
```

Os perfis já registram a mesma foto antes, no pico e depois de cada execução
(`capacidade.csv` no diretório do resultado). Conferência manual:

| Item | Comando | Referência |
|---|---|---|
| Memória | `free -g` | 2,2 GB no FS com 2000 sessões (A14): projeta ~6 GB com 5500 |
| Threads | `systemctl show freeswitch -p TasksMax,LimitNPROC` e `sysctl kernel.threads-max` | ~1 thread por sessão: 2024 threads com 2000 sessões (A14) |
| Portas RTP | `grep -E 'rtp-(start\|end)-port' /etc/freeswitch/autoload_configs/switch.conf.xml` | sem os parâmetros, vale o padrão 16384-32768 (~8 mil sessões RTP, 2 portas cada). `bypass_media=0`: 2 legs com RTP por chamada, ~5000 por FS no `stfc-c5000` mais o tráfego real |
| Timeout de mídia | `grep -rE 'rtp-timeout-sec\|media_timeout' /etc/freeswitch` | com `MEDIA=none` não há RTP: um timeout menor que o hold (500 s) derruba as chamadas |
| Memória do OpenSIPS | `opensips-cli -x mi get_statistics shmem:` | 21,7% com 1962 diálogos (A14) |

Depois de cada execução, nos dois FS: `bash fs-limites.sh restaurar`.

### Perfil de CPS

Os perfis de simultâneas ficam em 10 CPS e não medem o que cresce com o CPS: escritas do
`core-db-dsn` no PXC (~34 UPDATE e ~4 INSERT por chamada em 27/10/2026), consultas do roteamento
(~90 SELECT por chamada), o `sps` dos FS e o atraso do .162 acima de ~20 CPS (A1). O
`stfc-cps30` cobre isso:

| Perfil | Rampa | Patamar | Simultâneas | Duração total | `fs-limites.sh aplicar` (nos 2 FS) |
|---|---|---|---|---|---|
| `stfc-cps30` | 10 a 30 CPS em 80 s (+5 a cada 20 s) | ~220 s em 30 CPS | ~900 (hold 30 s) | ~10 min | `150 1300` |

O `sps` do FS conta sessões, não chamadas: 30 CPS x 2 sessões x ~55% no .162 = ~33 por FS, longe
de 150. Na página Gargalos, acompanhe `MySQL: latencia media`, `PXC: replicacao pausada por flow
control` e `FreeSWITCH: handles do banco em uso` contra o INVITE -> 200. Antes do perfil:

```bash
# nos dois FS (.163 e .162)
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh aplicar 150 1300
```

Perfil novo: depois de copiar para `/etc/flux-loadtest/profiles.d/`, rode de novo o
`flux-host.sh prepare zabbix-agent` (comandos abaixo). O include do agent tem um `AllowKey` por
perfil e, sem isso, o Zabbix descobre o `stfc-cps30` mas o agent recusa o disparo.

```bash
install -d -m 0755 /etc/flux-loadtest/profiles.d && install -m 0644 /opt/flux-loadtest/deploy/stfc-completo/profiles/stfc-*.conf /etc/flux-loadtest/profiles.d/ && ls -l /etc/flux-loadtest/profiles.d
```

Plano, sem alterar nada (troque `IP_DO_ZABBIX`):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --zabbix-server IP_DO_ZABBIX --dry-run
```

Aplicação, depois de revisar o plano:

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --zabbix-server IP_DO_ZABBIX && /opt/flux-loadtest/install/flux-host.sh check zabbix-agent
```

No `loadtest.conf`, o IP pelo qual o Zabbix alcança o agent do .165 (e, se quiser, o grupo que
pode executar os scripts):

```
ZABBIX_GEN_AGENT=IP_DO_165_VISTO_PELO_ZABBIX
ZABBIX_SCRIPT_USRGRP=
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix setup --scripts -c /etc/flux-loadtest/loadtest.conf
```

Uso: *Monitoring > Hosts*, menu do host `flt-gen` > **Flux Loadtest** > Iniciar perfil
(com confirmação), Plano (dry-run), Parar teste (parada suave), Estado. O teste com SIP exige
`FS_CLI_PASSWORD_FILE` no `loadtest.conf`, já usado na campanha. Diagnóstico:

```bash
journalctl -u flux-loadtest-zbx -n 50 --no-pager
```

## 6. Sem alertas para o suporte

As ações de notificação do Zabbix de produção (Telegram e e-mail) não têm condição: qualquer
gatilho chegaria ao suporte, inclusive os do guard durante um teste. Para evitar isso sem mudar
gatilhos, templates ou ações, os hosts `flt-*` ficam numa **manutenção com coleta de dados**:

| Item | Valor |
|---|---|
| Nome | `Flux Loadtest - sem alertas ao suporte` |
| Alvo | grupo de hosts `Flux Loadtest` (os 7 `flt-*`; os hosts reais ficam fora) |
| Tipo | com coleta de dados: os valores chegam e o dashboard funciona |
| Validade | 180 dias a partir de 22/10/2026 (até 20/04/2027) |
| Efeito | problemas dos `flt-*` suprimidos: as ações pausam suprimidos e a visão padrão de problemas não os mostra |

Para recriar: *Data collection > Maintenance > Create maintenance period*, com coleta de dados,
grupo `Flux Loadtest` e um período único. Para voltar a alertar: apagar a manutenção.

Alternativa definitiva, decisão do suporte: nas ações de notificação, a condição "tag `scope`
diferente de `loadtest`" (todos os gatilhos do flux-loadtest têm essa tag).

## Estado em produção (22/10/2026)

| Item | Estado |
|---|---|
| Zabbix | `zabbixnew.flux.net.br` (7.2.3), server `200.159.177.242` |
| Hosts | `flt-run`, `flt-opensips`, `flt-fs1`, `flt-fs2`, `flt-db1`, `flt-db2`, `flt-gen` (grupo `Flux Loadtest`) |
| Dashboard | `Flux Loadtest - Resultados (flt-)` |
| Execuções importadas | as 9 de 21/10/2026. As 8 primeiras foram enviadas a partir de cópias, fora do .165: os diretórios delas no .165 não têm `zabbix.sent`; **não reenviar**, o Zabbix duplicaria os valores |
| Envio ao vivo | ativo (`ZABBIX_SERVER=200.159.177.242` no `loadtest.conf` do .165) |
| Agent do .165 | o `zabbix-agent` 6.0.14 do Debian que já monitorava o host; include em `/etc/zabbix/zabbix_agentd.conf.d/flux-loadtest.conf`, ao lado do `userparameter_fluxsbc.conf` |
| Host `flt-gen` | interface agent `200.159.177.165:10050` e template de disparo |
| Scripts do menu | restritos ao grupo `Zabbix administrators`; perfis `stfc-piloto`, `stfc-cps20`, `stfc-c1000` |
| Primeiro uso | `stfc-cps20` iniciado pelo menu em 22/10/2026 02:57 e parado pelo "Parar teste" (código 6) |
| Manutenção | seção 6 |

**Achados na instalação do agent no .165** (corrigidos no repositório):

| Problema | Correção |
|---|---|
| O include ia para `/etc/zabbix/zabbix_agentd.d/` (pacote oficial); o agent do Debian lê `/etc/zabbix/zabbix_agentd.conf.d/*.conf` | O `prepare` usa o diretório do `Include=` do agent (#13) |
| A auditoria do agent abortava quando um include não tinha a chave procurada (`pipefail`) | #14 |
| A validação usava `zabbix_agentd -T`, que o agent 6.0 não tem; o include era sempre restaurado | Sem `-T`, valida com `zabbix_agentd -c CONF -t agent.ping` (#15) |
| O `prepare` sem `--dry-run` pede `SIM`; um filtro `\| grep` no comando esconde a pergunta e parece travado | Rodar sem filtro |

Templates do flux-loadtest vinculados a hosts reais (`Flux Loadtest - FreeSWITCH` e `OpenSIPS`
em `SBC-STFC-162`/`SBC-STFC-163`; `Gerador` e `Execucao` em `SBC-STFC-INTERFACEWEB`) não
recebem dados nesses hosts: desvincular.

## Reversão

O `zabbix-agent` do .165 já existia e monitora o servidor: a reversão tira só o que o
flux-loadtest acrescentou.

| Item | Como desfazer |
|---|---|
| Agent no .165 | Remover `/etc/zabbix/zabbix_agentd.conf.d/flux-loadtest.conf` e `systemctl restart zabbix-agent`; remover `/etc/sudoers.d/flux-loadtest-zbx`, `/usr/local/sbin/flux-loadtest-zbx` e `/etc/flux-loadtest/profiles.d/`. Backup do estado anterior em `/var/backups/flux-loadtest/20261022-024752` |
| Envio ao vivo | Esvaziar `ZABBIX_SERVER` no `loadtest.conf` |
| Hosts, templates, scripts e dashboard | No Zabbix: excluir o grupo de hosts `Flux Loadtest` e seus hosts, os templates do grupo `Templates/Flux Loadtest`, os scripts do menu `Flux Loadtest` e o dashboard |
| Manutenção | Excluir `Flux Loadtest - sem alertas ao suporte` |
| Token | Revogar em *Users > API tokens* e apagar `/etc/flux-loadtest/zabbix_api.token` |
