# Como interpretar os resultados

Este é o método para ler uma execução, do `report.txt` à conclusão. Siga os passos em ordem: um
resultado só vale se a execução for válida, e um gargalo só é confirmado depois de descartadas as
leituras que enganam.

A página [Leitura por equipe](por-equipe.md) aplica o mesmo método ao que cada equipe precisa
decidir.

## 1. A execução é válida?

Antes de olhar a meta, confirme que os números medem os servidores, e não o gerador ou um erro de
configuração.

| Verificação | Onde | Execução válida quando |
|---|---|---|
| Código de saída | terminal, `console.log` | `0`. Com `6`, leia `abort.txt`: os dados até a interrupção valem, mas a meta não foi completada |
| Gerador | tabela `gen` em "Servidores por fase" | `cpu_pct` abaixo de 60% (runbook do STFC) e `sipp_max_thread_pct` longe de 100 |
| Relógio | seção "Diferença de relógio" | Abaixo de 2 s para todos os servidores |
| Coleta completa | tabelas `fs*`, `opensips`, `db*` | Colunas `fs_*`, `os_*`, `db_*` preenchidas. `fs_*` vazias = `run` sem a senha do `fs_cli` |
| Rampa | seção SIP | "Pico de CPS" igual ao `-r` pedido, com a janela cobrindo a rampa mais 2 minutos no alvo |
| Regime | seção SIP | "Pico de chamadas simultâneas" perto de CPS x hold (veja o passo 2) |

!!! warning "Degrau que não chegou ao alvo não mede o alvo"
    Com a rampa padrão, um degrau de 25 CPS só chega a 25 depois de ~115 s. Na campanha, degraus de
    60 e 90 s pareciam saudáveis porque não ficaram tempo suficiente no alvo; com 240 s, o atraso
    apareceu.

## 2. A meta foi atingida?

### Falhas

| Linha do relatório | Significado |
|---|---|
| Falhas | Chamadas sem 200 OK ou com erro no diálogo, com o percentual |
| timeout de retransmissão UDP | O destino não respondeu (rede, firewall, fail2ban ou servidor travado) |
| resposta inesperada (4xx/5xx) | O destino recusou: veja "Falhas por motivo" |
| Falhas por motivo | Contagem por resposta SIP (`resposta 503 ...`), extraída do `errors.log` |

Os dois 503 mais comuns têm origens diferentes:

| Resposta | Quem responde | Causa |
|---|---|---|
| `503 Maximum Calls In Progress` | FreeSWITCH | `max-sessions` do nó atingido |
| `503 No FreeSWITCH Available` | OpenSIPS (`load_balancer`) | Nenhum destino com capacidade: todos cheios (`os_lb_max_pct`) ou um FS retirado por não responder à sondagem |

### Simultâneas

Compare o pico de simultâneas com o esperado (CPS x hold):

| Pico medido | Leitura |
|---|---|
| Perto de CPS x hold | Regime normal |
| Bem abaixo | Falhas cedo, janela curta, `-n` atingido ou `-l` baixo |
| Acima, até o teto do SIPp `CPS x (hold + 4) x 1,2` | **Chamadas acumulando:** o atendimento demora e cada chamada fica mais tempo ativa. É sinal de atraso, não de capacidade sobrando |

### Atendedor

| Linha | Leitura |
|---|---|
| Chamadas recebidas do FS = criadas | Todas chegaram ao fim do caminho |
| Originadas que não chegaram aqui > 0 | Recusadas antes do bridge (OpenSIPS, dialplan, limite de canais): veja as falhas do originador e o log do FS |
| sem BYE no prazo > 0 | O FS não repassou o BYE da perna B (perda de pacote, FS sobrecarregado ou route set errado) |

### Término das chamadas

"Encerradas pela VM (fim do hold)" é o caminho normal. "Encerradas pelo FS (BYE remoto)" acima de 0
indica que o FS desligou antes do hold: timeout de mídia (comum com `-M none` e hold longo), limite
de duração ou erro no dialplan.

## 3. A qualidade foi aceitável?

| Indicador | Significado |
|---|---|
| INVITE -> 100 | Tempo até o primeiro destino reconhecer o INVITE. Sobe quando o SIP fica em fila |
| INVITE -> 200 | Atraso pós-discagem (PDD) visto pela operadora: inclui OpenSIPS, dialplan, banco, bridge e o atendedor |

Compare com a referência do mesmo ambiente sem carga (piloto ou degrau baixo). Na campanha do STFC:

| Situação | INVITE -> 200 |
|---|---|
| Saudável (até ~15 CPS) | ~100 a 170 ms (p90) |
| Início da degradação (19 CPS) | 436 ms (p90) |
| Degradado (23 CPS) | ~2 s (p90) |
| Gatilho do Zabbix | média acima de 1000 ms |

A média esconde a cauda e a divisão por FS. Para saber **onde** fica o atraso, capture no gerador
durante o degrau e use o `pdd-pcap.py`, que separa por FS e por trecho:

```bash
tcpdump -i ens192 -nn -s0 -w /root/degrau.pcap 'udp port 5060 or udp port 5090'
```

```bash
python3 /opt/flux-loadtest/deploy/stfc-completo/pdd-pcap.py /root/degrau.pcap --gen 200.159.177.165 --uas-port 5090 --faixa 20
```

| Trecho | Do | Até | Inclui |
|---|---|---|---|
| Ida | INVITE do originador | INVITE do bridge chegando ao atendedor | OpenSIPS, `load_balancer`, dialplan Lua + MySQL, bridge |
| Volta | 200 do atendedor | 200 chegando ao originador | FS e OpenSIPS repassando |
| Total | INVITE do originador | 200 dele | Tudo |

Um FS com total p90 muito maior que o outro, com a mesma carga, aponta para o nó, não para o banco
ou o OpenSIPS.

## 4. Onde está o gargalo?

Compare as fases na tabela "Servidores por fase": o que muda de `baseline` para `sip` é o custo do
teste. Leia na ordem abaixo; o primeiro recurso no limite costuma ser a causa, e os seguintes,
consequência.

| # | O que olhar | Gargalo quando |
|---|---|---|
| 1 | `<processo>_max_thread_pct` e `cpu_max_core_pct` | Perto de 100 com `cpu_pct` baixo: uma thread saturada (o total engana) |
| 2 | `fs_sessions_pct`, `fs_sps` | Perto de 100% do `max-sessions` ou do `sessions-per-second` |
| 3 | `fs_idle_cpu`, `fs_api_ms` | CPU ociosa do FS baixa e `status` lento: CPU do FS |
| 4 | `fs_db_probe_ms`, `fs_db_handles_pct` | `show calls count` lento com `status` rápido: banco interno ou pool de handles |
| 5 | `os_lb_max_pct` | Destino do `load_balancer` perto de 100: capacidade publicada pelos FS esgotada |
| 6 | `os_load`, `opensips_max_thread_pct`, `os_tm_inuse` | Workers do OpenSIPS ocupados ou transações acumulando |
| 7 | `os_shm_used_pct` | Memória compartilhada subindo com transações (CPS x atraso) |
| 8 | `db_stmt_avg_ms`, `db_threads_running`, `mysqld_max_thread_pct` | Banco lento ou com fila |
| 9 | `db_wsrep_fc_paused_pct`, `db_wsrep_recv_queue` | Um nó do cluster atrasado travando as escritas |
| 10 | `udp_rcvbuf_err_s`, `net_rx_drop_s`, `softirq_pct` | Pacotes perdidos no kernel ou na interface |
| 11 | `iowait_pct`, `disk_busy_pct` | Disco (logs, banco interno, gravações) |

Correlação sintoma -> gargalo, quando o INVITE -> 200 sobe:

| O que sobe junto | Gargalo provável | Onde confirmar |
|---|---|---|
| `fs_db_handles_pct` perto de 100, ou `fs_db_probe_ms` alto com `fs_api_ms` rápido e `db_stmt_avg_ms` baixo | Pool de conexões do FS (`max-db-handles`, `db-handle-timeout`) | `fs_cli -x 'db_cache status'`; com `loglevel` DISABLE o aviso `Max handles ... exceeded` não aparece no log |
| `fs_db_probe_ms` e `db_stmt_avg_ms` altos | Banco (core db ou consultas do dialplan) | `db_threads_running`, flow control, consultas lentas |
| `freeswitch_max_thread_pct` perto de 100 com CPU total baixa | Uma thread do FS (ex.: loop do sofia-sip) | Diagnóstico de threads no FS durante o patamar |
| `fs_api_ms` alto e `fs_idle_cpu` baixo | CPU do FS | `cpu_pct`, `fs_idle_cpu` |
| `os_load` alto ou `opensips_max_thread_pct` perto de 100 | Workers do OpenSIPS ou algo lento no script | `os_tm_inuse` |
| `os_lb_max_pct` perto de 100 | Capacidade do `load_balancer` (o FS ainda pode ter folga) | `lb_list`, `fs-limites.sh mostrar` |
| `udp_rcvbuf_err_s` ou `net_*_drop_s` acima de 0 | Rede ou buffer do kernel | `net.core.rmem_max`, `softirq_pct` no núcleo mais carregado |
| `sipp_max_thread_pct` perto de 100 | Gerador: o teste deixou de medir os servidores | CPU do gerador |
| Nenhum dos acima | Atraso fora do que o coletor mede | Captura e `pdd-pcap.py`; captura entre OpenSIPS e FS |

## 5. O ambiente voltou ao normal?

| Verificação | Normal |
|---|---|
| `cooldown` x `baseline` | CPU, sessões, diálogos, transações e memória de volta aos valores do baseline |
| `fs_sessions` no cooldown | Igual ao baseline. Sessões sobrando = pernas presas (ex.: BYE que não chegou) |
| `os_active_dlg` no cooldown | Igual ao baseline. Diálogos sobrando expiram só pelos timers |
| Capacidade `antes` x `depois` | Sem aumento de `drop_requests`, diálogos com falha ou `RcvbufErrors` |
| `snapshots/*-pre.txt` x `-post.txt` | `status` do FS e `lb_list` equivalentes |

## 6. Semáforo por indicador

Critérios para classificar um degrau. Cada corte tem a origem indicada; ajuste ao ambiente, mas
registre o critério usado.

| Indicador | Verde | Amarelo | Vermelho | Origem |
|---|---|---|---|---|
| Falha SIP | 0 | até 1% | acima de 2% (STFC) ou 5% (padrão) | Runbook; `GUARD_MAX_FAIL_PCT` |
| Originadas que não chegaram | 0 | — | acima de 0 | Runbook |
| Respostas 503 | 0 | — | qualquer | Runbook |
| INVITE -> 200 médio | próximo do piloto | crescendo com a carga | acima de 1000 ms | `{$FLT.SIP.PDD.MAX}` |
| CPU de um SBC | abaixo de 70% | 70 a 75% | acima de 75% (STFC) ou 85% | Runbook; `GUARD_MAX_CPU_PCT` |
| CPU do gerador | abaixo de 60% | 60 a 70% | acima de 70% (STFC) | Runbook; `GUARD_MAX_GEN_CPU_PCT` |
| Thread mais carregada | abaixo de 70 | 70 a 85 | acima de 85 | `{$FLT.THREAD.MAX}` |
| `fs_sessions_pct` | abaixo de 70% | 70 a 90% | acima de 90% | `{$FLT.FS.SESSIONS.PCT}` |
| `fs_idle_cpu` (mínimo) | acima de 30 | 10 a 30 | abaixo de 10 | `{$FLT.FS.IDLE.MIN}` |
| `fs_api_ms`, `fs_db_probe_ms` | estável | crescendo | acima de 500 ms | `{$FLT.FS.PROBE.MAX}` |
| `fs_db_handles_pct` | abaixo de 50% | 50 a 80% | acima de 80% | `{$FLT.FS.DBH.PCT}` |
| `os_lb_max_pct` | abaixo de 70% | 70 a 85% | acima de 85% | `{$FLT.OS.LB.MAX}` |
| `os_shm_used_pct` | abaixo de 50% | 50 a 80% | acima de 80% | `{$FLT.OS.SHM.MAX}` |
| `os_load` | abaixo de 50% | 50 a 70% | acima de 70% | `{$FLT.OS.LOAD.MAX}` |
| `os_failed_dlg_total`, `os_drop_req_total` | +0 | — | acima de +0 | Gatilho de contador |
| `db_stmt_avg_ms` | abaixo de 10 ms | 10 a 20 ms | acima de 20 ms | `{$FLT.DB.LAT.MAX}` |
| `db_conn_pct` | abaixo de 60% | 60 a 80% | acima de 80% | `{$FLT.DB.CONN.MAX}` |
| `db_wsrep_fc_paused_pct` | 0 | até 10% | acima de 10% | `GUARD_MAX_WSREP_FC_PCT` |
| `db_wsrep_state` / `primary` | 4 / 1 | — | outro valor | Guard |
| `udp_rcvbuf_err_s`, `net_*_drop_s` (SBC) | 0 | — | acima de 0 | Runbook; `{$FLT.NET.DROP.MAX}` |
| `iowait_pct` | abaixo de 10% | 10 a 20% | acima de 20% | `{$FLT.IOWAIT.MAX}` |
| `disk_free_pct` (mínimo) | acima de 30% | 15 a 30% | abaixo de 15% | `GUARD_MIN_DISK_FREE_PCT` |
| `mem_used_pct` | abaixo de 70% | 70 a 85% | acima de 85% (STFC) | `GUARD_MAX_MEM_PCT` |

Os cortes de "amarelo" que não vêm de uma fonte (as faixas intermediárias) são sugestões para
antecipar o vermelho; o vermelho segue sempre o guard, o runbook ou a macro do Zabbix.

**Veredito do degrau:**

| Veredito | Quando |
|---|---|
| Atingido | Execução válida, meta cumprida e nenhum indicador vermelho |
| Atingido com ressalva | Meta cumprida, com algum indicador amarelo: registre qual e a margem que sobra |
| Parcial | Execução interrompida ou com falhas, mas com dados que mostram até onde o sistema foi |
| Não atingido | O sistema não sustentou a carga; registre o gargalo e a evidência |
| Não atingível | Não executado porque um limite conhecido impede (ex.: `max-sessions`) |
| Inconclusivo | Execução inválida (passo 1): repita |

## 7. Leituras que enganam

| O que parece | O que é |
|---|---|
| `receive timeout ... jumping to label` no `errors.log` | **Não é erro**: é o fim do hold, a VM envia o BYE. O relatório conta como "fim do hold" |
| `udp_rcvbuf_err_s` alto no gerador com `-M rtp` | Esperado: o rtpstream do SIPp não consome o RTP devolvido pelo FS. Não afeta o teste |
| `freeswitch_cpu_pct` = 210 | 2,1 núcleos, não 210% do servidor |
| `cpu_pct` de 30% "com folga" | Pode haver uma thread a 100%: olhe `*_max_thread_pct` e `cpu_max_core_pct` |
| O `.163` aparece duas vezes | `opensips` e `fs1` são o mesmo servidor: as colunas de sistema se repetem, a CPU é a soma dos dois serviços |
| `db_repl_lag = -1` | Normal no PXC (não há réplica assíncrona) |
| Pico de simultâneas maior que o esperado | Chamadas acumulando por atraso, não capacidade sobrando |
| `os_shm_used_pct` baixo com muitas simultâneas | A memória do OpenSIPS cresce com transações (CPS x atraso), não com diálogos estáveis |
| Execução interrompida = teste perdido | Os dados até a interrupção valem e mostram onde o limite foi atingido |
| `max` do `lb_list` fixo | O OpenSIPS recalcula com o que o FS publica (sessões e CPU ociosa); cai sob carga |
| `fs_*` vazias | `run` sem a senha do `fs_cli`, não FS parado |
| Falha logo após aplicar `fs-limites.sh` | O `load_balancer` leva ~30 s para ler a nova capacidade |

## 8. Contas úteis

| Pergunta | Conta |
|---|---|
| Quantas simultâneas este degrau gera? | CPS x hold |
| Quantas sessões no FS mais carregado? | simultâneas x 2 x ~0,55 |
| Qual `max-sessions` aplicar? | 1,4 x simultâneas por FS |
| Quantas consultas por chamada? | (`db_qps` médio na fase `sip` - `db_qps` médio no `baseline`) / CPS médio da fase |
| Quanto da CPU é mídia? | `freeswitch_cpu_pct` com `-M rtp` - com `-M none`, mesma carga |
| Quantas portas RTP? | 2 por perna com mídia; com `bypass_media = 0`, 2 pernas por chamada |
| Quanto o banco aguenta, por projeção? | Uso na fase / CPS medido, extrapolado até o limite do guard. Projeção, não medida: confirme com um degrau |

## 9. Subir ou não o próximo degrau

**Não suba** se houver qualquer um destes (runbook do STFC):

- falhas SIP acima de 1%, ou "Originadas que não chegaram" acima de 0;
- respostas 503 (limite do FS ou `load_balancer`);
- CPU de algum SBC acima de 70%, ou do gerador acima de 60%;
- `udp_rcvbuf_err_s` nos SBC ou flow control no PXC;
- reclamação de clientes ou alerta do NOC.

Também não suba se o cooldown não voltou ao baseline (passo 5) ou se a execução foi inválida
(passo 1). Resolva a causa, repita o mesmo degrau e só então avance.

Registre cada degrau no [modelo de registro](modelo-de-registro.md).
