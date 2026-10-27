# Métricas coletadas

O `lib/collector.sh` é enviado por `ssh ... bash -s` com `nice -n 10`. Ele lê `/proc`, `df` e os
comandos de status, escreve CSV no stdout e termina sozinho quando o SSH cai ou o tempo máximo acaba.
Não instala nada e não grava nada no servidor.

## Convenções

| Sufixo | Significado |
|---|---|
| `*_pct` | Percentual. Nas colunas de **processo** (`freeswitch_cpu_pct`...), 100 = 1 núcleo |
| `*_s` | Taxa por segundo no intervalo |
| `*_total` | Contador acumulado; o relatório mostra a variação na fase (`+N`) |
| `*_ms` | Milissegundos |
| `*_mb`, `*_mbps`, `*_kbs` | MB, Mbit/s, kB/s |

Processos são identificados pelo nome exato ou nome + versão (`php-fpm7.3`), para não contar
`mysqld_safe` ou `opensips-cli`.

## Comuns a todos os servidores

| Coluna | O que é | Como ler |
|---|---|---|
| `cpu_pct` | CPU do servidor inteiro | Média de todos os núcleos: esconde um núcleo saturado |
| `cpu_max_core_pct`, `cpu_max_core` | Núcleo mais carregado e qual é | Perto de 100 com `cpu_pct` baixo = uma thread ou a softirq da rede no limite |
| `iowait_pct` | CPU esperando disco | Acima de 20 indica disco lento (gatilho do Zabbix) |
| `steal_pct` | CPU tomada pelo hipervisor | Acima de 0 sustentado: a VM disputa CPU no host |
| `softirq_pct` | Tratamento de interrupções (rede) | Sobe com pps; concentrado num núcleo limita a rede |
| `load1` | Load average de 1 min | Comparar com o número de núcleos |
| `mem_used_pct`, `mem_avail_mb`, `swap_used_mb` | Memória | Swap subindo durante o teste é sinal de risco |
| `net_rx_mbps`, `net_tx_mbps`, `net_rx_pps`, `net_tx_pps` | Tráfego (todas as interfaces, sem `lo`) | Custo de mídia: compare `-M none` e `-M rtp` |
| `udp_in_err_s`, `udp_rcvbuf_err_s` | Erros UDP e descartes por buffer cheio | Acima de 0 nos SBC: pacotes SIP/RTP perdidos no kernel |
| `net_rx_drop_s`, `net_tx_drop_s` | Descartes na interface | Acima de 0: rede ou fila da placa |
| `disk_rd_kbs`, `disk_wr_kbs`, `disk_busy_pct`, `disk_free_pct` | Disco | `disk_free_pct` é vigiado pelo guard |

## Por processo

| Coluna | O que é |
|---|---|
| `<processo>_cpu_pct` | CPU do processo (100 = 1 núcleo; 210 = 2,1 núcleos) |
| `<processo>_rss_mb` | Memória residente |
| `<processo>_threads` | Threads (no FS, ~1 por sessão) |
| `<processo>_max_thread_pct` | Thread que mais usou CPU no intervalo (no OpenSIPS e no PHP-FPM, o processo); 100 = 1 núcleo inteiro |

## FreeSWITCH (`freeswitch`)

| Coluna | O que é | Como ler |
|---|---|---|
| `fs_calls` | Chamadas ativas | Deve acompanhar as simultâneas do SIPp no FS |
| `fs_sessions` | Sessões ativas (2 por chamada de teste) | Comparar com `fs_max_sessions` |
| `fs_sps` | Sessões por segundo | Comparar com o `sessions-per-second` do nó |
| `fs_idle_cpu` | CPU ociosa vista pelo FS (mínimo na fase) | Abaixo de 10 = FS sem CPU (gatilho) |
| `fs_api_ms` | Tempo do `fs_cli status` | Sobe quando o FS está sobrecarregado |
| `fs_db_probe_ms` | Tempo do `show calls count`, que consulta o banco interno | Alto com `fs_api_ms` baixo = banco interno lento ou pool esgotado |
| `fs_max_sessions`, `fs_sessions_pct` | Limite em uso e ocupação | Acima de 90% = perto de `503 Maximum Calls In Progress` |
| `fs_db_handles`, `fs_db_handles_used`, `fs_db_handles_pct` | Pool do core db (`db_cache status`) em % do `max-db-handles` | Acima de 80% = criação de canal pode esperar até `db-handle-timeout` |

## OpenSIPS (`opensips`)

| Coluna | O que é | Como ler |
|---|---|---|
| `os_active_dlg`, `os_early_dlg` | Diálogos ativos e em estabelecimento | `early` alto = chamadas demorando para ser atendidas |
| `os_tm_inuse` | Transações em uso | Cresce com CPS x atraso e com retransmissões |
| `os_rcv_req_s` | Requisições recebidas por segundo | Inclui retransmissões |
| `os_failed_dlg_total`, `os_drop_req_total` | Diálogos com falha e requisições descartadas | Qualquer `+N` na fase merece explicação |
| `os_shm_used_pct` | Memória compartilhada | Acima de 80% (gatilho); cresce com transações, não com diálogos |
| `os_load` | Ocupação dos workers (`load:load`) | Acima de 70% (gatilho) |
| `os_lb_max_pct` | Destino do `load_balancer` mais cheio (load / max) | Acima de 85% = perto de `503 No FreeSWITCH Available` |

## MySQL / PXC (`mysqld`)

| Coluna | O que é | Como ler |
|---|---|---|
| `db_qps`, `db_select_s`, `db_insert_s`, `db_update_s` | Consultas por segundo, total e por tipo | Dividido pelo CPS dá consultas por chamada |
| `db_threads_running`, `db_threads_connected` | Consultas executando e conexões | `running` acima do número de núcleos = fila no banco |
| `db_conn_pct` | Conexões / `max_connections` | Acima de 80% (gatilho) |
| `db_stmt_avg_ms` | Latência média das instruções no intervalo (`performance_schema`) | Acima de 20 ms (gatilho); vazio sem permissão no `performance_schema` |
| `db_slow_total`, `db_row_lock_waits_total` | Consultas lentas e esperas por lock | Qualquer `+N` merece explicação |
| `db_repl_lag`, `db_repl_ok` | Réplica assíncrona | `-1` = sem réplica assíncrona, o normal no PXC |
| `db_wsrep_state` | `4` = Synced; `1` Joining, `2` Donor, `3` Joined | Fora de 4 interrompe o teste |
| `db_wsrep_primary` | `1` = o nó tem quórum | `0` interrompe o teste |
| `db_wsrep_cluster_size` | Nós no cluster | Abaixo de `GUARD_MIN_WSREP_CLUSTER_SIZE` interrompe |
| `db_wsrep_fc_paused_pct` | % do intervalo com a replicação pausada por flow control | Acima de 10 interrompe: um nó atrasado trava as escritas do cluster |
| `db_wsrep_recv_queue`, `db_wsrep_send_queue` | Filas de write-sets | Fila crescendo num nó = nó atrasado |
| `db_vip` | `1` = o VIP está neste nó | Mostra qual nó recebe as consultas |

## Web (`nginx`, `php-fpm`)

| Coluna | O que é | Como ler |
|---|---|---|
| `ngx_active`, `ngx_rps`, `ngx_writing`, `ngx_waiting` | `stub_status` do nginx | Vazias sem o `stub_status` |
| `fpm_active`, `fpm_idle` | Workers ocupados e livres | `fpm_idle` 0 = pool esgotado |
| `fpm_listen_queue` | Requisições esperando worker | Acima de 0 = PHP-FPM com fila (gatilho) |
| `fpm_max_children_total` | Vezes que o pool chegou em `pm.max_children` | `+N` = aumentar o pool ou investigar lentidão |
| `fpm_rps`, `fpm_slow_total` | Requisições por segundo e lentas | — |

## VM de teste (`gen`)

Processos `sipp`, `wrk` e `sysbench`, mais as colunas comuns. `sipp_max_thread_pct` perto de 100
significa que o gerador é o limite e os números deixam de medir os servidores.
