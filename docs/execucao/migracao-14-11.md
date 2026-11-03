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
| T3 | `stfc-cps-livre` a 40 CPS, parando o FreeSWITCH de um nó | Comportamento do `load_balancer` e capacidade com um nó |
| T4 | `stfc-cps90-2h`, com a configuração final | Vazamento de memória e degradação |

### Coletas durante T1, T2 e T4

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

Dispare `stfc-cps-livre` com 40 CPS e, com a carga no patamar, pare um nó. Sem tráfego real, o impacto é só no
teste. O guard de falhas pode parar a execução, e isso também é resultado:

```bash
systemctl stop freeswitch
```

No `.163`, acompanhe o tempo até o `load_balancer` tirar o nó:

```bash
opensips-cli -x mi lb_list | grep -E '"(uri|max|load|enabled)"'
```

Depois do teste, religue o nó:

```bash
systemctl start freeswitch && sleep 10 && fs_cli -x status | head -n 3
```

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
