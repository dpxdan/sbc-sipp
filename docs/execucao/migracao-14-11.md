# Migração de 14/11

Os servidores entram em produção em 14/11/2026, com meta de **90 CPS no sistema**. Este roteiro lista o que
falta comprovar e o que precisa sair antes da migração. Até lá, não há tráfego real nesses servidores.

## Critério de aceite de 90 CPS

| Medida | Limite |
|---|---|
| Falhas no chamador | Até 0,1% |
| INVITE -> 200 médio | Abaixo de 200 ms |
| Pior período de 5 s | Abaixo de 1 s |
| CPU de pico em cada nó | Abaixo de 85% |
| Conexões do banco | Abaixo de 80% |
| Memória do OpenSIPS, máximo real | Abaixo de 80% |
| Descartes UDP | 0 |
| Duração | Patamar de 30 min, sem degradar |

## Preparação no `.165`

```bash
cd /opt/flux-loadtest && git pull --ff-only && git log --oneline -1
```

```bash
install -m 0644 /opt/flux-loadtest/deploy/stfc-completo/profiles/stfc-cps90-*.conf /etc/flux-loadtest/profiles.d/ && ls /etc/flux-loadtest/profiles.d | grep cps90
```

Acrescente o guard de conexões e suba o teto de janela, necessário para o teste de 2 h:

```bash
grep -q '^GUARD_MAX_DB_CONN_PCT=' /etc/flux-loadtest/loadtest.conf || echo 'GUARD_MAX_DB_CONN_PCT=80' >> /etc/flux-loadtest/loadtest.conf; sed -i 's/^ZBX_MAX_WINDOW=.*/ZBX_MAX_WINDOW=7500/' /etc/flux-loadtest/zabbix-runner.conf; grep -E '^(GUARD_MAX_|BASELINE|COOLDOWN)' /etc/flux-loadtest/loadtest.conf; grep ZBX_MAX /etc/flux-loadtest/zabbix-runner.conf
```

Atualize o include do agent, os scripts do menu e o template, que ganhou o item de memória máxima:

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent
```

```bash
./flux-loadtest.sh zabbix setup --import-template --scripts -c /etc/flux-loadtest/loadtest.conf
```

Confira as três dependências que não puderam ser testadas fora do `.165`:

```bash
sipp -v | head -n 2; awk -W version 2>&1 | head -n 1; ls -l /etc/alternatives/awk
```

Depois do primeiro teste:

- `net_rx_mbps` deve deixar de ser 0 em `metrics/*.csv`;
- o atendedor não deve ter `Aborting call` com `INVITE`.

## Testes

Antes de cada um, nos dois FS: `fs-limites.sh aplicar 150 1260`. Rode em um teste por vez.

| Teste | Como | O que responde |
|---|---|---|
| T1 | `stfc-cps90-30min` | 90 CPS sustentado e causa das travadas |
| T2 | `stfc-cps90-rtp-escada`, depois `stfc-cps90-rtp-30min` se chegar a 90 | Limite com RTP em todas as chamadas, o pior caso |
| T3 | `stfc-cps-livre` a 40 CPS, parando e religando o FreeSWITCH do `.162` no patamar | Comportamento do `load_balancer` e capacidade com um nó |
| T4 | `stfc-cps90-2h`, com a configuração final e o `coleta-longa.sh` nos servidores | Vazamento de memória e degradação |
| T5 (opcional) | `stfc-opensips-teto` | Teto do OpenSIPS com INVITE a 90 CPS |

### Coletas durante T1, T2 e T4

No T4, o `diag-travadas.sh` (fila da 5060) e o `coleta-longa.sh` (conexões do banco) substituem as duas coletas
abaixo; veja a seção "T4: 2 h a 90 CPS".

No `.163`, a fila do socket do OpenSIPS, 5 vezes por segundo, mostra início e duração de cada travada. Ajuste o
`timeout` à duração do teste:

```bash
timeout 2400 bash -c 'while sleep 0.2; do printf "%s " "$(date +%T.%3N)"; ss -lunm "src 200.159.177.163:5060" | grep -o "skmem:(r[0-9]*"; done' > /root/fila-5060.log
```

No `.161`, as conexões por origem:

```bash
timeout 2400 bash -c 'while sleep 5; do date +%T; mysql -N -e "SELECT user, SUBSTRING_INDEX(host,\":\",1), COUNT(*) FROM information_schema.processlist GROUP BY 1,2 ORDER BY 3 DESC LIMIT 6;"; done' > /root/conexoes-db1.log
```

Depois de cada teste, no `.161`:

```bash
mysql -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Max_used_connections','Max_used_connections_time','Connection_errors_max_connections','Aborted_connects');"
```

O `Connection_errors_max_connections` estava em 4 em 31/10 e não deve subir.

### Travadas do OpenSIPS

No T1, a fila do socket 5060 parou de ser lida por 1,3 a 2,2 s em ciclo fixo de 150 s (56,5 + 56,5 + 37 s), sem
falhas, mas com ~1% das chamadas entre 1 e 2 s até o 200.

**Causa (03/11):** log. Com `xlog_level=3`, os `xlog("L_NOTICE", ...)` das rotas geravam ~3.000 linhas/s a 90 CPS
(~33 por chamada). O journald descartava ~65 mil a cada 30 s pelo limite de taxa e não acompanhava, e os 8 workers da
5060 ficavam bloqueados no envio ao socket de log (`sock_alloc_send_pskb`). **Correção:** `xlog_level=1`, aplicado
sem restart com `opensips-cli -x mi xlog_level 1` e gravado no `opensips.cfg`. Para depurar uma chamada, suba para 3
pelo MI e volte para 1.

| `stfc-cps-livre` a 90 CPS | `xlog_level=3` | `xlog_level=1` |
|---|---|---|
| Falhas | 0 | 0 |
| INVITE -> 100 / -> 200 (média) | 10 / 126 ms | 1 / 101 ms |
| Pior período de 5 s | 593 ms | 110 ms |
| Chamadas com 500 ms ou mais até o 200 | 2,22% | 0 |
| Retransmissões de INVITE | 677 | 0 |
| Fila máxima do socket 5060 | 1,4 MB | 10 KB |
| Escrita em disco no `.163` (média) | 3,5 MB/s | 0,12 MB/s |

Para repetir o diagnóstico, rode `stfc-cps-livre` a 90 CPS (~9 min) com, no `.163`:

```bash
bash /root/diag-travadas.sh 600
```

O script (`deploy/stfc-completo/diag-travadas.sh`, só leitura) grava em `/root/diag-travadas-<data>/` o `wchan`
de cada processo do OpenSIPS no momento da travada, as threads mais carregadas, a fila da 5070 do FS e, a cada
1 s, o tempo de resposta do MI e o `max` do `load_balancer`. Leitura do `wchan` dos workers SIP na travada:

| `wchan` | Indica |
|---|---|
| `futex_wait_queue` | Lock interno do OpenSIPS, mantido por outro processo (timer, MI, `load_balancer`) |
| `sk_wait_data`, `wait_woken`, `unix_stream_*` | Espera de rede: banco ou event socket do FS |
| `R` com CPU alta | Falta de CPU no `.163` |

No `.161`, em paralelo, as consultas de 1 s ou mais:

```bash
timeout 600 bash -c 'while sleep 0.5; do mysql -N -e "SELECT NOW(3), id, user, SUBSTRING_INDEX(host,\":\",1), command, time, state, LEFT(info,200) FROM information_schema.processlist WHERE command <> \"Sleep\" AND time >= 1 AND user NOT IN (\"system user\",\"event_scheduler\");"; done' > /root/lentas-db1.log
```

No `.162`, a fila da 5070, para saber se o outro FS para junto:

```bash
timeout 600 bash -c 'while sleep 0.2; do printf "%s " "$(date +%T.%3N)"; ss -Hlunm "src 200.159.177.162:5070" | grep -o "skmem:(r[0-9]*"; done' > /root/fila-5070-162.log
```

### T2: mídia

Os DIDs de teste precisam de `bypass_media = 1` (no FluxSBC, `1` desativa o bypass e o FS ancora o RTP) e `leg_timeout` diferente de 0 ([Conta e DIDs de teste](../instalacao/massa-dids.md)),
e o firewall do `.165` precisa liberar as faixas RTP vindas dos FS.

O teste com RTP coloca ~180 Mbit/s por sentido no gerador a cada 1000 simultâneas. Acompanhe `SIPp: thread mais
carregada`: perto de 100%, o gerador passa a limitar, e o número deixa de medir os servidores.

### Resultado do T2 (03/11, `stfc-cps90-rtp-30min`)

Execução `20261103-030628-zbx-stfc-cps90-rtp-30min`: rampa de 45 a 90 CPS das 03:07:36 às 03:12:36 e patamar
de 30 min em 90 CPS, com RTP nas duas pernas e `xlog_level=1`. Limites dos FS em `sps=300` e
`max_sessions=5000` (os do `switch.conf`).

| Medida | Limite | Medido | Situação |
|---|---|---|---|
| Falhas no chamador | Até 0,1% | 0 de 180.902 (atendedor: 0 de 180.902) | Ok |
| INVITE -> 200 médio | Abaixo de 200 ms | 110 ms (INVITE -> 100: 3 ms) | Ok |
| Pior período de 5 s | Abaixo de 1 s | 178 ms (03:32:27) | Ok |
| CPU de pico em cada nó | Abaixo de 85% | **.163: 88,1%** (média 68%, núcleo mais carregado 93%); .162: 77,9%; .161: 45,3% | **Fora** |
| Conexões do banco | Abaixo de 80% | 9% (45 de 500) | Ok |
| Memória do OpenSIPS, máximo real | Abaixo de 80% | 17,4% (`shm_max` 23,2%, sem crescer) | Ok |
| Descartes UDP | 0 | 0 nos servidores (ver gerador abaixo) | Ok |
| Duração | 30 min sem degradar | CPS de 89,6 a 90,2 em todos os períodos do patamar | Ok |

Distribuição e ocupação no patamar:

- **Chamadas:** ~920 simultâneas (pico 1108 no SIPp, com o timewait); 917 diálogos no OpenSIPS. O `.162` recebeu
  ~55% (pico de 586 chamadas e 1151 sessões) e o `.163`, ~45% (466 e 928).
- **FreeSWITCH:** ~4 núcleos de CPU em cada FS (`freeswitch_cpu_pct` médio de 408 no `.163` e 416 no `.162`). A
  mídia é a maior parte da CPU: o OpenSIPS usou ~21% de um núcleo.
- **Limites dos FS:** sessões em até 23% de `max_sessions`, portas RTP em até 6%, handles do banco em até 26%.
- **Banco:** ~6.500 consultas/s no `.161` (`mysqld` em ~1,5 núcleo, pico de 3,3), latência média de 0,2 ms, PXC
  `Synced`, sem flow control.

**Gargalo: CPU do `.163` (OpenSIPS e fs1 no mesmo servidor).** O guard registrou CPU acima de 85% no fs1 às
03:15:45 e entre 03:32:51 e 03:33:47. As 221 retransmissões do SIPp ficaram nesses mesmos minutos: 38 às 03:16 e
112 entre 03:30 e 03:34, contra 0 a 8 por minuto no resto. O atraso não chegou ao chamador (pior período de
178 ms), mas a folga é pequena. Com a mídia, 90 CPS fica no limite de CPU do `.163` (achado A4).

**Disco do `.162`:** o uso subiu ~5 GB durante o teste (de 16 GB para 21 GB, ~2,2 MB/s de escrita), o que dá
~50 KB por chamada. No `.163`, o disco não mudou. É preciso descobrir o que foi gravado antes do T4 (2 h), por
exemplo com `find / -xdev -type f -newermt '2026-11-03 03:07' -size +10M -exec ls -lh {} +` no `.162`.

**Descartes no gerador:** o `.165` contou ~85 mil `udp_rcvbuf_errors` por segundo, praticamente todo o RTP
recebido. O `rtp_stream` do SIPp só envia e não lê os pacotes que chegam, então isso não é perda nos servidores.
O volume recebido (~86 mil pps, quase 2 pernas x 920 chamadas x 50 pps) confirma que os FS ancoraram e
encaminharam o RTP das duas pernas. O gerador não mede a qualidade da mídia: perda e jitter dependem de captura
nos FS.

### T3: queda de um FS

Pare o FreeSWITCH do `.162` com `stfc-cps-livre` a 40 CPS no patamar e religue-o antes do fim. Toda a carga cai no
`.163`, que também roda o OpenSIPS: é o pior caso de CPU. O teste responde:

- quanto tempo o `load_balancer` leva para tirar o nó;
- o que acontece com as chamadas em curso e com as que chegam durante a detecção;
- se um nó sozinho aguenta 40 CPS;
- como a carga volta a se dividir quando o nó retorna.

Linha do tempo do perfil a 40 CPS (fases da execução de 03/11):

| t (s) | Fase |
|---|---|
| 0-60 | baseline |
| 60-360 | rampa de 20 a 40 CPS |
| 360-540 | patamar de 40 CPS |
| 390 | parar o FS do `.162` |
| 480 | religar o FS do `.162` |

São 90 s com um nó e 60 s para medir o retorno, ainda no patamar.

#### Antes de disparar

Nos dois FS, aplique os limites (confira os valores no "Plano stfc-cps-livre (CPS)" com 40):

```bash
bash fs-limites.sh aplicar 150 1260
```

No `.162`, confirme que não há chamadas além das do teste. Parar o FreeSWITCH derruba todas as chamadas do nó:

```bash
fs_cli -x 'show channels count'
```

No `.163`, confira os timers e o probing em produção. No cfg do lab: `fr_timeout 5`, `probing_interval 10` e
`lb_disable_dst()` no 408:

```bash
grep -nE 'fr_timeout|fr_inv_timeout|probing_interval|probing_method|lb_disable_dst' /etc/opensips/opensips.cfg
```

No `.163`, deixe a captura do `lb_list` rodando, uma linha por segundo:

```bash
while sleep 1; do printf '%s ' "$(date +%T)"; opensips-cli -x mi lb_list | grep -E '"(uri|enabled|load)"' | tr -d ' \n'; echo; done | tee /tmp/t3-lb.log
```

#### Disparo

No Zabbix, dispare "Iniciar stfc-cps-livre (CPS)" com 40. No mesmo instante, no `.162`:

```bash
sudo bash -c 'sleep 390; date "+%F %T parando"; systemctl stop freeswitch; date "+%F %T parado"; sleep 90; date "+%F %T iniciando"; systemctl start freeswitch; sleep 10; date "+%F %T ativo"; fs_cli -x status | head -n 3' 2>&1 | tee /tmp/t3-fs2.log
```

Quando aparecer "ativo", reaplique os limites no `.162`. `fsctl sps` e `fsctl max_sessions` não sobrevivem ao
restart: o nó volta com os valores do `switch.conf`.

```bash
bash fs-limites.sh aplicar 150 1260
```

#### Depois do teste

Nos dois FS:

```bash
bash fs-limites.sh restaurar
```

No `.163`, pare o laço com Ctrl+C e separe os eventos de failover (rotas com os nomes do cfg do lab; ajuste se o de
produção for diferente):

```bash
journalctl -u opensips --since "-30 min" | grep -E 'FS_FAILOVER|lb-disable|pool-esgotado' > /tmp/t3-failover.log
```

Guarde o diretório da execução do `.165`, `/tmp/t3-lb.log` e `/tmp/t3-failover.log` do `.163` e `/tmp/t3-fs2.log` do
`.162`.

#### O que esperar

Valores derivados do perfil, do runner e do cfg do lab, ainda não medidos:

- **Chamadas em curso no `.162`:** ~200 (40 CPS x 10 s / 2). O FS encerra todas com BYE. O cenário UAC trata BYE
  remoto como fim normal: elas aparecem em "Encerradas pelo FS (BYE remoto)" no `report.txt`, não como falha.
- **INVITEs para o `.162` antes da detecção:** ficam sem resposta até o `fr_timeout`. O 408 desabilita o nó e a
  chamada é refeita no `.163`. Com `SIP_RECV_TIMEOUT_MS=60000`, elas completam com ~5 s de atraso.
- **Guard de atraso (2000 ms):** deve marcar 1 ou 2 amostras de 5 s; a parada exige 3 seguidas. Se parar, o tempo de
  detecção está longo demais, e isso também é resultado.
- **Um nó só:** CPU do `.163` em até ~67%, o mesmo patamar por FS dos 80 CPS de 31/10, com metade da carga do
  OpenSIPS.
- **Retorno:** o probing reabilita o nó em até 10 s e o CPS por FS volta a ~50/50.

| Critério | Esperado |
|---|---|
| Falhas SIP | 0 |
| Tempo até o `.162` sair do pool | até o `fr_timeout` (≤ 5 s) ou o probing (≤ 10 s) |
| INVITE -> 200 acima de 1 s | só durante a detecção |
| CPU do `.163` com um nó | < 85% |
| Tempo até o `.162` voltar ao pool | ≤ 10 s, com a carga redividida |

Para medir a capacidade de um nó por mais tempo, repita o perfil a 40 CPS com o FS do `.162` parado desde antes do
disparo: os ~13 min ficam só no `.163`.

### T4: 2 h a 90 CPS

Confirma que nada cresce com o tempo: memória do FreeSWITCH e do OpenSIPS, latência, conexões do banco e disco.
`stfc-cps90-2h` sobe de 45 a 90 CPS em 5 min (+9 a cada 60 s) e fica 2 h a 90 CPS, só sinalização, hold de
10 s: ~667 mil chamadas, ~2h08 com baseline e cooldown.

O runner grava a cada 5 s o que já aparece no relatório. O `coleta-longa.sh` completa, por minuto, o que um teste
longo precisa: RSS, PSS e VmHWM por processo, shm e pkg do OpenSIPS (`get_statistics`), sessões e limites do
FS, contadores do banco e, no fim, os arquivos e diretórios que mais cresceram, que respondem o disco do `.162`
visto no T2. Somente leitura; `fs_cli` e `mysql` usam a configuração local do root.

#### Antes de disparar

Copie `coleta-longa.sh` e `diag-travadas.sh` de `/opt/flux-loadtest/deploy/stfc-completo/` no `.165` para
`/root` do `.163`, `.162`, `.161` e `.164` (o `diag-travadas.sh` só no `.163`), como nos testes anteriores.

Nos dois FS, os limites precisam ser iguais (300 / 5000). No T3, um `/root/flux-loadtest-fs-limites.antes`
antigo deixou o FS1 em 150 / 1260 e a carga se dividiu 25 / 75:

```bash
bash fs-limites.sh mostrar
```

```bash
cat /root/flux-loadtest-fs-limites.antes
```

Se o arquivo tiver valores abaixo do `switch.conf`, apague-o e aplique os valores do `switch.conf` (`fsctl` muda
os limites em runtime, sem restart e sem afetar chamadas em curso):

```bash
rm -f /root/flux-loadtest-fs-limites.antes
```

```bash
bash fs-limites.sh aplicar 300 5000
```

No `.163`, confirme `xlog_level` em 1:

```bash
opensips-cli -x mi xlog_level
```

Espaço em disco: ~100 MB de resultados no `.165`; no `.162`, folga para ~30 GB se o crescimento do T2 (~50 KB
por chamada) se repetir. O guard para o teste com menos de 15% livre.

```bash
df -h / /var/lib/freeswitch /var/lib/flux-loadtest 2>/dev/null
```

Valide o coletor em cada servidor com 2 min, intervalo de 10 s, e confira se o pacote saiu com os arquivos do
papel do servidor (`fs.tsv` nos FS, `opensips-stats.log` no `.163`, `db.tsv` nos bancos):

```bash
bash coleta-longa.sh 120 10
```

#### Disparo

Em cada servidor, dentro de um `tmux`, inicie o coletor logo antes do disparo. 7900 s cobrem o teste e uma margem:

```bash
tmux new -s t4
```

```bash
bash coleta-longa.sh 7900
```

No `.163`, em outra janela do `tmux`:

```bash
bash diag-travadas.sh 7900
```

No Zabbix, rode "Plano stfc-cps90-2h" e depois "Iniciar stfc-cps90-2h".

Durante o teste, acompanhe o `console.log` no `.165` e, no Zabbix, CPS por FS, CPU por servidor e pacotes. O
guard para o teste sozinho em CPU, memória, disco, falhas, atraso, memória do OpenSIPS e conexões do banco.

#### Depois do teste

Os coletores terminam sozinhos, fazem a busca de arquivos (alguns minutos) e geram o pacote. Nos dois FS:

```bash
bash fs-limites.sh restaurar
```

Envie:

- do `.165`: `/var/lib/flux-loadtest/results/<execução>.tar.gz`;
- do `.163`, `.162`, `.161` e `.164`: `/root/coleta-longa-<host>-<data>.tar.gz`;
- do `.163`: a pasta `/root/diag-travadas-<data>/`.

#### Critério do T4

Os critérios de aceite de 90 CPS e, comparando os três terços do patamar de 2 h:

| Medida | Esperado |
|---|---|
| RSS / PSS do FreeSWITCH, `.163` e `.162` | Sem alta contínua entre os terços; volta perto do valor de antes depois do teste |
| shm e pkg do OpenSIPS | Sem alta contínua; `max_used_size` da shm abaixo de 80% |
| INVITE -> 200 e pior período de 5 s | Sem tendência entre os terços |
| `Connection_errors_max_connections` | Sem aumento |
| Disco | Crescimento explicado por `arquivos-crescidos.txt` e compatível com a operação real |

### T5: teto do OpenSIPS

Os FS limitam o sistema antes do OpenSIPS, então o teto dele nunca foi medido. O `stfc-opensips-teto` mantém INVITE a
90 CPS pelo caminho real e, a partir de 300 s, sobe uma escada de OPTIONS de 500 a 5000/s. O OpenSIPS responde esses
OPTIONS sozinho (rota `options-keepalive`), sem banco e sem FS: a carga extra fica só nele.

Antes, no `.165`, acrescente ao `/etc/flux-loadtest/loadtest.conf` os guards de OPTIONS e instale o perfil:

```bash
grep -q '^GUARD_MAX_OPTIONS_FAIL_PCT=' /etc/flux-loadtest/loadtest.conf || printf 'OPTIONS_LOCAL_PORT=5062\nGUARD_MAX_OPTIONS_FAIL_PCT=1\nGUARD_MAX_OPTIONS_RT_MS=100\n' >> /etc/flux-loadtest/loadtest.conf; install -m 0644 /opt/flux-loadtest/deploy/stfc-completo/profiles/stfc-opensips-teto.conf /etc/flux-loadtest/profiles.d/
```

Rode com `bash /root/diag-travadas.sh 1500` no `.163`. A seção "OPTIONS ao OpenSIPS" do relatório traz a tabela por
degrau, o teto sustentado e o motivo da parada:

- falha ou resposta de OPTIONS acima do limite: teto do OpenSIPS;
- CPU do `.163` acima de 85% com resposta normal: teto do host, que divide a CPU com um FS. O OpenSIPS isolado iria
  além, e a coluna `opensips` (CPU do processo) mostra quanto ele usava.

## Decisão em 05-06/11

Se o T2 não chegar a 90 CPS dentro do critério, o caminho depende de capacidade da INFRA: mais vCPU nos FS, um
terceiro FS ou separar o OpenSIPS do FS no `.163`. É o maior risco para a data. Leve também a latência de ~1 ms entre
os hosts do `.162`/`.164` e do `.161`/`.163`.

## Antes da migração

Siga [Encerramento e reversão](encerramento.md), mais estes pontos:

- **Senha do event socket:** trocar, atualizando `/etc/flux-loadtest/fs_cli.pass` no `.165` e nos FS, `/root/.fs_cli_conf`
  e o que o OpenSIPS usar. Reinicie o `fluxsbc-cps` em cada FS.
- **Persistência:** conferir depois de um restart `S_MEMORY=256`, `maxbuffer`, `net.core.rmem_max`, `xlog_level=1`
  no `opensips.cfg`, `max_connections` nos dois nós do PXC e os limites do `switch.conf`.
- **Limites:** rodar `fs-limites.sh restaurar` nos dois FS.
- **Zabbix:** revogar os tokens de teste, desvincular os templates `Flux Loadtest` dos hosts reais e definir os alertas
  reais dos FS. O template de CPS não tem gatilhos, e as ações de notificação não têm condição.
- **Gerador:** o `.165` é a interface web de produção. Depois da migração, o teste de carga não pode rodar nele:
  desative os perfis com `ZABBIX_ENABLED=0` ou remova o agent de disparo.
