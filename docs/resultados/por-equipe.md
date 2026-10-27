# Leitura por equipe

Cada equipe lê a mesma execução com uma pergunta diferente. As seções abaixo dizem o que olhar, onde
olhar, o limite e a ação. O método completo está em [Como interpretar](como-interpretar.md); os
cortes do semáforo, na [seção 6](como-interpretar.md#6-semaforo-por-indicador) de lá.

Fontes:

- **report.txt**: o relatório da execução (seções e tabelas por fase);
- **CSV**: `metrics/<host>.csv`, `capacidade.csv`, `sip/stats.csv`;
- **Zabbix**: dashboard `Flux Loadtest - Resultados`, páginas Resultados, Gargalos e Servidores.

---

## Gestão e produto

**Pergunta:** a meta foi atingida, e o que impede a próxima?

| O que olhar | Onde | Como decidir |
|---|---|---|
| Veredito por meta | Registro de cada degrau ([modelo](modelo-de-registro.md)) | Atingido, atingido com ressalva, parcial, não atingido, não atingível, inconclusivo |
| Capacidade atual | Maior degrau sem indicador vermelho | É o número a comunicar ("~20 CPS com PDD aceitável", "~2000 simultâneas") |
| O que limita | Gargalo do degrau que falhou | Um componente e uma evidência, não uma lista de suspeitos |
| Custo de avançar | Recomendação da equipe técnica | Ajuste em runtime (sem impacto), mudança com restart (janela) ou novo hardware |

Como ler o resultado:

- "Não atingível" é um resultado: diz que um limite de configuração conhecido impede a meta, sem
  gastar janela de produção.
- Uma projeção (ex.: "a CPU do banco chegaria ao limite perto de 100 CPS") não é uma medida. Só vira
  capacidade depois de confirmada num degrau.
- Capacidade de CPS e de simultâneas são independentes: uma meta pode ser atingida e a outra não.

Modelo de resumo para a diretoria, a partir da campanha de 21/10/2026:

| Meta | Resultado | Medido | O que limitou |
|---|---|---|---|
| 1000 simultâneas | Atingida | 1022, 0 falha, INVITE -> 200 de 145 ms | — |
| 2000 simultâneas | Parcial | 1962; 7,3% de falha no fim da subida | `max-sessions` 2000 por FS |
| 100 CPS | Não atingida | Falhas a partir de 40-50 CPS | Fila SIP no FS do `.162` e `load_balancer` sem destino |
| CPS sustentável | ~20 CPS | p90 de ~170 ms até 15 CPS, 436 ms a 19 CPS | Fila SIP no FS do `.162` |

---

## NOC e suporte

**Pergunta:** o teste está afetando clientes, e quando parar?

### Antes do teste

- Janela combinada, em horário de menor tráfego, com o responsável pelo ambiente.
- Hosts `flt-*` em manutenção com coleta no Zabbix (senão os gatilhos do teste chegam ao suporte).
- Gerador na whitelist do Event Guard e do fail2ban (senão ele é banido no meio do degrau).
- Picos de tráfego real anotados no preflight: a margem dos limites é calculada a partir deles.

### Durante o teste

| Sinal | Onde | Ação |
|---|---|---|
| `503 Maximum Calls In Progress` ou `503 No FreeSWITCH Available` | "Falhas por motivo"; página Resultados do Zabbix | Os 503 atingem **também clientes**: o guard deve parar; se não parar, "Parar teste" ou Ctrl+C |
| Gatilho "Execução interrompida" | Zabbix, host `flt-run` | Confirmar o motivo em `abort.txt` e avisar o responsável pela janela |
| Reclamação de cliente ou alerta de produção | Canais do NOC | Parar o teste (parada suave) e registrar o horário |
| CPU de SBC acima de 70% | Página Servidores do Zabbix | Avisar quem conduz o teste: não subir o próximo degrau |

Como parar:

- **Ctrl+C uma vez** no terminal do gerador, ou **"Parar teste"** no menu do Zabbix: parada suave
  (as chamadas ativas terminam, cooldown e relatório; código 6).
- **Ctrl+C duas vezes:** a carga é encerrada na hora.

### Depois do teste

- Conferir que o cooldown voltou ao baseline (sessões e diálogos).
- Confirmar a reversão: limites do FS restaurados, origem removida da `address`, regras de firewall
  removidas (veja [Encerramento](../execucao/encerramento.md)).

---

## Voz (FreeSWITCH e OpenSIPS)

**Pergunta:** qual componente de sinalização ou mídia é o limite, e qual ajuste o move?

### FreeSWITCH

| Métrica | Limite | Leitura e ação |
|---|---|---|
| `fs_sessions_pct` | 90% | Perto de `503 Maximum Calls In Progress`. Ação: `max-sessions` = 1,4 x simultâneas (`fs-limites.sh` para testar; `switch.conf` para valer) |
| `fs_sps` | `sessions-per-second` do nó | Lembre que conta **sessões**: 2 por chamada |
| `fs_idle_cpu` | 10 | CPU do FS esgotada |
| `fs_api_ms` | 500 ms | FS lento para responder ao event socket: sobrecarga ou thread presa |
| `fs_db_probe_ms` | 500 ms | Banco interno lento (SQLite local ou `core-db-dsn`) ou pool esgotado |
| `fs_db_handles_pct` | 80% | Pool do core db perto do `max-db-handles`; a criação de canal pode esperar até `db-handle-timeout` |
| `freeswitch_max_thread_pct` | 85 | Uma thread perto de um núcleo inteiro (ex.: sofia-sip): o FS para de escalar mesmo com CPU total baixa |
| `freeswitch_threads` | `TasksMax`/`LimitNPROC` (capacidade) | ~1 thread por sessão: confira o teto antes de degraus grandes |
| BYE remoto, "sem BYE no prazo" | 0 | Timeout de mídia menor que o hold, ou pernas presas |

Compare **os dois nós**: o `load_balancer` não sabe das diferenças de configuração entre eles. Na
campanha, o `.162` atrasava e o `.163` não, com a mesma carga, e o `switch.conf` dos dois era
diferente (`sps`, banco interno, `max-db-handles`). Para isolar o nó:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh mostrar
```

```bash
python3 /opt/flux-loadtest/deploy/stfc-completo/pdd-pcap.py /root/degrau.pcap --gen 200.159.177.165
```

### OpenSIPS

| Métrica | Limite | Leitura e ação |
|---|---|---|
| `os_lb_max_pct` | 85% | Destino do `load_balancer` perto do `max`: `503 No FreeSWITCH Available` em seguida. Confira `lb_list` |
| `os_shm_used_pct` | 80% | Cresce com transações em andamento (CPS x atraso), não com diálogos estáveis. Ação: `-m` maior (restart) antes de CPS alto |
| `os_load`, `opensips_max_thread_pct` | 70%, 85 | Workers ocupados: `children`/`udp_workers` ou script lento |
| `os_tm_inuse`, `os_early_dlg` | crescendo | Transações acumulando: o destino demora a responder |
| `os_failed_dlg_total`, `os_drop_req_total` | +0 | Qualquer aumento na fase precisa de explicação |
| `os_rcv_req_s` | — | Inclui retransmissões: muito acima de CPS x mensagens por chamada indica retransmissão |

```bash
opensips-cli -x mi lb_list | grep -E '"(uri|max|load)"'
```

```bash
opensips-cli -x mi get_statistics shmem:
```

### Mídia

- Compare um degrau com `-M none` e o mesmo com `-M rtp`: a diferença de `freeswitch_cpu_pct` e
  `net_*_pps` é o custo de mídia.
- Com `bypass_media = 0`, o FS ancora o RTP das duas pernas; com `1`, o RTP passa direto e o FS só
  sinaliza.

---

## Banco (DBA)

**Pergunta:** o banco limita as chamadas, e quanto cada chamada custa?

| Métrica | Limite | Leitura e ação |
|---|---|---|
| `db_qps` | — | Divida pelo CPS (descontando o baseline) para ter consultas por chamada |
| `db_stmt_avg_ms` | 20 ms | Latência média das instruções; vazia sem `SELECT` no `performance_schema` |
| `db_threads_running` | número de núcleos | Fila de consultas |
| `mysqld_max_thread_pct` | 85 | Uma thread de aplicação no limite (na campanha, um núcleo chegou a 100% com 2000 simultâneas) |
| `db_conn_pct` | 80% | Perto de `max_connections` |
| `db_wsrep_fc_paused_pct` | 10% | Flow control: o nó mais lento trava as escritas do cluster. Compare `db_wsrep_recv_queue` dos dois nós |
| `db_wsrep_state`, `db_wsrep_primary`, `db_wsrep_cluster_size` | 4, 1, 2 | Qualquer outro valor interrompe o teste; verifique o cluster antes de repetir |
| `db_vip` | — | Mostra o nó que recebe as consultas: compare a carga dos dois |
| `db_slow_total`, `db_row_lock_waits_total` | +0 | Consultas lentas e locks na fase |
| `disk_wr_kbs`, `iowait_pct` | 20% | Escritas do `core-db-dsn` e do billing |

Consultas por chamada medidas na campanha: ~240 (~37 UPDATE e ~6 INSERT). Para ver quais:

```sql
SELECT digest_text, count_star, ROUND(avg_timer_wait/1e9, 2) AS avg_ms
  FROM performance_schema.events_statements_summary_by_digest
 ORDER BY count_star DESC LIMIT 20;
```

Outros clientes do mesmo cluster também contam: na campanha, a interface web e seus crons eram o
maior cliente do banco (`events_statements_summary_by_host_by_event_name`).

---

## Infraestrutura e sistema operacional

**Pergunta:** algum recurso de máquina, rede ou SO está no limite?

| Métrica | Limite | Leitura e ação |
|---|---|---|
| `cpu_pct` | 75% (STFC) | CPU do servidor inteiro |
| `cpu_max_core_pct` | 85-100 | Núcleo saturado (thread ou softirq de rede) |
| `steal_pct` | acima de 0 sustentado | O hipervisor está tirando CPU da VM |
| `softirq_pct` | concentrada num núcleo | Interrupções de rede num só núcleo: RSS/RPS da placa |
| `iowait_pct`, `disk_busy_pct` | 20% | Disco lento |
| `mem_used_pct`, `swap_used_mb` | 85%, crescendo | Memória; swap durante o teste é risco |
| `udp_rcvbuf_err_s` | acima de 0 nos SBC | Buffer UDP do kernel cheio: `net.core.rmem_max` e o buffer do socket do serviço |
| `net_rx_drop_s`, `net_tx_drop_s` | acima de 0 | Descartes na interface |
| `net_rx_pps`, `net_tx_pps` | — | Volume de pacotes (RTP domina com `-M rtp`) |
| `disk_free_pct` | 15% | Vigiado pelo guard; nunca reduzir o limite |
| Threads, `LimitNPROC`, `TasksMax`, `LimitNOFILE` | 80% (capacidade) | Teto de threads e arquivos do serviço |
| Diferença de relógio | 2 s | NTP/chrony em todos os servidores |

Para descartar a rede como causa de atraso, compare o que um servidor enviou com o que o outro
recebeu (`nstat` antes e depois, e uma captura nos dois lados). Na campanha, o `.162` recebeu
20.106 datagramas para 20.099 enviados pelo `.163`, sem descarte: a rede foi descartada.

---

## Web (interface)

**Pergunta:** a interface aguenta a carga, e ela disputa recursos com as chamadas?

| Métrica | Onde | Leitura e ação |
|---|---|---|
| req/s, latência p50/p90/p99, erros | Seção "Web" (por alvo) | Compare o estático (só nginx) com o PHP (nginx + PHP-FPM + sessão no banco) |
| Estático rápido, PHP lento | — | Gargalo no PHP-FPM ou no banco, não no nginx |
| `fpm_listen_queue` | `metrics/web.csv` | Acima de 0: requisições esperando worker |
| `fpm_idle` = 0, `fpm_max_children_total` +N | `metrics/web.csv` | Pool esgotado: `pm.max_children` ou lentidão das requisições |
| `ngx_active`, `ngx_waiting` | `metrics/web.csv` | Conexões no nginx |
| `php_fpm_cpu_pct`, `nginx_cpu_pct` | "Servidores por fase" | CPU por processo (100 = 1 núcleo) |
| `db_qps` durante `web_php` | tabelas `db*` | Custo da interface no banco |

- O teste PHP reutiliza **um** cookie de sessão; ele mede a página com sessão existente, não o login.
- HTTP 500 com "authentication method unknown to the client" é o PHP 7.3 sem suporte a
  `caching_sha2_password`: o usuário da aplicação precisa de `mysql_native_password`.
- Quando o gerador roda no próprio servidor web (como o `.165` na campanha), a CPU do servidor é
  dividida entre o SIPp e a interface.
