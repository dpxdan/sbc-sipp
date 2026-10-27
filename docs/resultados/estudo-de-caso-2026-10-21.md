# Estudo de caso: campanha de 21/10/2026

A campanha da WEB-1437 no STFC, lida com o método de [Como interpretar](como-interpretar.md). O
registro completo, com todos os achados, é o
[`deploy/stfc-completo/RESULTADOS.md`](https://github.com/dpxdan/sbc-sipp/blob/master/deploy/stfc-completo/RESULTADOS.md).

Todas as execuções usaram `-t sip -M none`, alvo pelo OpenSIPS e os limites do FS do `switch.conf`.

## Resultado por meta

| Meta | Resultado | Medido | O que limitou |
|---|---|---|---|
| 1000 simultâneas | Atingida | 1022 simultâneas, 1515/1515 chamadas, INVITE -> 200 de 145 ms | — |
| 2000 simultâneas | Parcial | 1962 simultâneas; 7,3% de falha no fim da subida (guard) | `max-sessions` 2000 por FS |
| 3000 simultâneas | Não atingível (não executada) | — | Teto de ~2000 chamadas: 2 FS x 2000 sessões / 2 sessões por chamada |
| 100 CPS | Não atingida | Rampa chegou a 50 CPS; falhas a partir de 40-50 CPS (10,7%), INVITE -> 200 de 4,6 s | Fila SIP no FS do `.162` e `load_balancer` sem destino |
| 200 e 300 CPS | Não atingíveis (não executadas) | — | O sistema não sustenta 100 CPS |
| CPS sustentável | ~20 CPS | Até 15 CPS: p90 de ~170 ms; 19 CPS: 436 ms; 23 CPS: 2 s | Fila SIP no FS do `.162` |
| 100 mil DIDs | Atingida | 100.000 DIDs em uso, roteamento estável em ~100 ms | — |

## Como cada conclusão saiu dos números

### 2000 simultâneas: o limite de sessões

Execução `stfc-meta-c2000` (`-r 10 -H 200 -w 260 -l 2100`), interrompida pelo guard em 212 s.

1. **Válida?** Sim: gerador folgado, coleta completa, CPS no alvo (10).
2. **Meta?** 1967/2122 chamadas, 155 falhas (7,3%). "Falhas por motivo": 37
   `503 No FreeSWITCH Available` e 18 `503 Maximum Calls In Progress`.
3. **Gargalo:** o `503 Maximum Calls In Progress` vem do FS. Na tabela do `fs2`, `fs_sessions` chegou
   a **2000**, igual ao `max-sessions`; o `fs1` estava em 1924. Em seguida, sem destino com
   capacidade, o `load_balancer` respondeu `503 No FreeSWITCH Available`.
4. **O resto aguentou:** INVITE -> 200 de 140 ms, `os_shm_used_pct` 21,7%, CPU do `.163` 21%.
5. **Conta:** 2 sessões por chamada -> 1000 chamadas por FS -> ~2000 no sistema, já com o tráfego
   real.

Conclusão: limite de **configuração**, não de recurso. Ação: `max-sessions` de 1,4 x simultâneas por
FS (perfis `stfc-c3000` e `stfc-c5000`).

### 100 CPS: atraso que cresce com o tempo

Execução `stfc-meta-cps100` (`-r 100 --cps-start 10 --ramp-step 10 --ramp-interval 20 -H 10 -w 240`),
interrompida em 91 s com 60% de falha no período.

1. **Válida?** Sim, mas a rampa só chegou a 50 CPS antes do guard.
2. **Meta?** 271 falhas (10,7%): 122 `503 No FreeSWITCH Available`, 27 `408`, 7 `480`. INVITE -> 200
   médio de **4615 ms**.
3. **Leitura que engana:** o `503 No FreeSWITCH Available` apareceu com só 716 simultâneas (830 e 616
   sessões nos FS, longe de 2000). Não é falta de sessões.
4. **CPU com folga:** `.163` em 38,6%, `.162` em 18%, banco em 31%. O gargalo não é CPU total.
5. **Separar por FS** (degraus de 25 CPS com captura e `pdd-pcap.py`):

| Degrau | FS | Total p50 / p90 |
|---|---|---|
| `stfc-cps25-rede2` | `.163` | 108 / 1768 ms |
| `stfc-cps25-rede2` | `.162` | **4743 / 11570 ms** |

6. **Dentro do `.162`** (captura no `.163`): até 15 CPS, o 100 Trying sai em ~10 ms; a 25 CPS
   sustentados, passa de 0,5 s para 1,8 s, e o ACK do 200 de 1 a 4 s, **mesmo com o CPS constante**.
   O tempo de roteamento (dialplan + banco) fica em ~100 ms do começo ao fim.
7. **Descartado com medição:** rede (o `.162` recebeu todos os datagramas, sem descarte nem
   `RcvbufErrors`), firewall, banco do Flux (roteamento constante), CPU (o FS do `.162` em 27% de
   média).

Conclusão: a fila está no processamento SIP do FreeSWITCH do `.162` (achado A1). Os suspeitos são as
diferenças de configuração entre os nós (`sessions-per-second` 50 contra 300, banco interno SQLite
contra MySQL). O `load_balancer` sem destino (A15) é consequência provável: o `.162` atrasado deixa de
responder à sondagem a tempo.

### O gerador também mostra o atraso

No `stfc-cps25-rede2`, o pico de simultâneas foi 720, exatamente o teto do SIPp
`25 x (20 + 4) x 1,2`. Com 25 CPS e hold de 20 s, o esperado era ~500: as chamadas se acumularam
porque demoravam a ser atendidas. Pico de simultâneas acima de CPS x hold é sintoma de atraso.

### Memória do OpenSIPS: projeção corrigida

| Situação | `os_shm_used_pct` |
|---|---|
| Repouso | 5,8% |
| 1962 diálogos estáveis, 117 transações | 21,7% |
| 297 diálogos, 1018 transações (50 CPS com retransmissões) | 38,5% |

A projeção anterior (por diálogo) previa estouro perto de 2000 chamadas. Os números mostram que a
memória acompanha as **transações em andamento** (CPS x atraso), não os diálogos.

## Recomendações que saíram da campanha

| Ordem | Ação | Achado |
|---|---|---|
| 1 | Resolver a fila SIP do `.162` (testar `sps` 300 em runtime; depois o banco interno) | A1 |
| 2 | Investigar o `load_balancer` sem destino (`lb_list` e log durante o degrau) | A15 |
| 3 | `-m` maior no OpenSIPS antes de CPS acima de 50 (restart) | A3 |
| 4 | `max-sessions` de 1,4 x simultâneas por FS | A14 |
| 5 | Igualar o `switch.conf` dos dois FS | A5 |
| 6 | Reduzir as ~240 consultas por chamada | A2 |

Com o A1 resolvido, a CPU do `.163` e do banco projetam um teto perto de 100 CPS. Para 200 a 300 CPS
serão necessários mais FS, o OpenSIPS em servidor próprio e menos consultas por chamada.
