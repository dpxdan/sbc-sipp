# Arquivos e relatório

Cada execução grava em `RESULTS_DIR/<AAAAMMDD-HHMMSS>-<label>/` e é empacotada em
`RESULTS_DIR/<execução>.tar.gz`.

## Arquivos

| Arquivo | Conteúdo | Quem usa |
|---|---|---|
| `report.txt` | Relatório consolidado | Todos |
| `run.env`, `hosts.tsv` | Parâmetros da execução e servidores (com o nome de cada um) | Reprodução do teste |
| `phases.tsv` | Fases com início e fim (epoch) | Cruzar com logs e Zabbix |
| `metrics/<host>.csv` | Amostras brutas do coletor (uma linha por `SAMPLE_INTERVAL`); `.err` com o stderr dele | Análise fina, gráficos |
| `sip/` | `stats.csv`, `errors.log`, `actions.log`, `screen.log`, `calls.csv` e o cenário gerado | Voz |
| `uas/` | Atendedor: `stats.csv`, `errors.log`, `sipp.stderr`, `uas.xml` | Voz |
| `web/`, `mysql/` | Saídas completas do `wrk` e do `sysbench` | Web, banco |
| `snapshots/<host>-pre.txt`, `-post.txt` | Estado antes e depois (`status`, `lb_list`, réplica, PHP-FPM) | Comparar antes e depois |
| `capacidade/`, `capacidade.csv`, `capacidade.txt` | Fotos de limites e uso `antes`/`pico`/`depois` e alertas | Voz, infra, banco |
| `guard.log` | Cada amostra acima de um limite | Entender uma interrupção |
| `abort.txt` | Motivo da interrupção (só quando houve) | Todos |
| `clock.tsv`, `console.log` | Diferença de relógio e saída do terminal | Validar a execução |
| `zabbix.log`, `zabbix.sent` | Envio ao Zabbix e marca de execução já enviada | Operação do Zabbix |

Para regenerar o relatório depois de atualizar o script (não precisa de configuração nem de SSH):

```bash
./flux-loadtest.sh report /var/lib/flux-loadtest/results/20261021-221500-stfc-meta-c1000
```

## Seções do `report.txt`

| Seção | Conteúdo | Pergunta que responde |
|---|---|---|
| Cabeçalho | Parâmetros, VM de teste, destino e origem SIP | O que foi testado? |
| Linha do tempo | Início, fim e duração de cada fase | A janela foi cumprida? |
| Limites de segurança | Interrupção, motivo e últimas ocorrências | O teste parou sozinho? Por quê? |
| SIP | Criadas, sucesso, falhas por tipo, BYE remoto, fim do hold, pico de simultâneas, CPS, INVITE -> 100 e -> 200, duração, falhas por motivo | A meta foi atingida, com qualidade? |
| Atendedor | Recebidas do FS, atendidas, falhas, sem BYE, originadas que não chegaram | O caminho completo funcionou? |
| MySQL | Transações, queries, latência média e p95 do sysbench | Como o banco responde à carga sintética? |
| Web | req/s, latência média e p50/p90/p99, erros, por alvo | Como a interface responde? |
| Capacidade | Alertas e tabela `antes`/`pico`/`depois` | Quanto dos limites foi usado? |
| Relógio | Diferença de cada servidor para a VM | Os timestamps são comparáveis? |
| Servidores por fase | Uma tabela por servidor: métrica x fase | Onde está o gargalo? |

### Exemplo: seção SIP e atendedor

Ilustrativo, com os números da execução `stfc-meta-c1000` de 21/10/2026 (10 CPS, hold 100 s):

```
== SIP (SIPp -> 200.159.177.163:5060)
  Chamadas criadas                     1515
  Concluidas com sucesso               1515
  Falhas                               0 (0.00%)
    timeout de retransmissao UDP       0
    resposta inesperada (4xx/5xx)      0
    rejeitadas                         0
  Encerradas pelo FS (BYE remoto)      0
  Encerradas pela VM (fim do hold)     1515
  Pico de chamadas simultaneas         1022
  Pico de CPS (por periodo)            10
  CPS medio da fase                    ...
  INVITE -> 100 (media)                ... ms
  INVITE -> 200 (media)                145 ms
  Duracao media da chamada             ... ms

== Atendedor (SIPp UAS em 200.159.177.165:5090)
  Chamadas recebidas do FS             1515
  Atendidas e encerradas (BYE)         1515
  Falhas                               0 (0.00%)
    mensagem inesperada                0
    sem BYE no prazo (hold + 120 s)    0
  Pico de chamadas simultaneas         ...
  Originadas que nao chegaram aqui     0
```

Como ler cada linha: [Como interpretar](como-interpretar.md).

### Tabela "Servidores por fase"

Uma tabela por servidor, com uma linha por métrica e uma coluna por fase:

```
-- fs2 (freeswitch, 200.159.177.162, sbc-stfc-02)
  metrica (media/pico)              baseline             sip       sip_drain        cooldown
  cpu_pct                            2.1/3.0        6.0/7.5         4.2/6.8         2.0/2.9
  fs_sessions                        12/18      980/1064        410/1010           11/16
  fs_idle_cpu                    97.8/96.9m    93.5/92.1m      95.1/93.0m      97.9/97.0m

-- opensips (opensips, 200.159.177.163, sbc-stfc-1)
  os_failed_dlg_total                   +0             +0              +0              +0
```

- Cada célula é `média/pico` da fase.
- `m` indica que o segundo número é o **mínimo** (disco livre, memória disponível, CPU ociosa do FS).
- `+N` é a variação de um contador acumulado (`*_total`) na fase.
- `*_cpu_pct` de processo: 100 = 1 núcleo. `cpu_pct`: percentual do servidor inteiro.

Os números acima ilustram o formato; os valores reais de cada execução estão no `report.txt` dela.

## Capacidade

A foto de capacidade (`lib/capacidade.sh`) registra os limites que definem quantas chamadas cabem e
quanto deles está em uso, em três momentos: `antes` (antes do baseline), `pico` (no fim da janela de
envio) e `depois` (depois do cooldown).

| Papel | O que é coletado |
|---|---|
| Todos | Memória total e disponível, swap, threads e `kernel.threads-max`, `RcvbufErrors`, `rmem_max`, disco livre |
| Processo (FS, OpenSIPS, MySQL) | Threads, RSS, `LimitNPROC`, `LimitNOFILE`, `TasksMax`, teto efetivo de threads e uso; arquivos abertos |
| FreeSWITCH | `max_sessions` e `sps` em uso e no `switch.conf`, sessões atuais e pico, `loglevel`, banco interno (SQLite ou ODBC), `max-db-handles` e handles em uso, faixa RTP e portas em uso, `rtp-timeout-sec`, `media_timeout` |
| OpenSIPS | Memória compartilhada (total, em uso, pico), diálogos ativos e com falha, transações, `drop_requests`, `max` e `load` de cada destino do `load_balancer` |
| MySQL / PXC | Conexões e `max_connections`, pico de conexões, `pxc_strict_mode`, threads de aplicação, flow control, filas |
| VM de teste | `ulimit -n` |

| Arquivo | Conteúdo |
|---|---|
| `capacidade/<fase>-<host>.env` | Foto bruta, uma linha `chave=valor` por métrica |
| `capacidade.csv` | Uma linha por servidor e métrica, uma coluna por fase e a coluna `alerta`; pronto para colar no caderno de testes |
| `capacidade.txt` | Alertas e tabela resumida (também no `report.txt`) |

Alertas gerados:

- uso em `*_pct` acima de `CAPACITY_ALERT_PCT` (80%), ou memória/disco livre abaixo de 20%;
- timeout de mídia menor ou igual ao hold;
- `loglevel` debug;
- `max_sessions` ou `sps` em uso diferentes do `switch.conf` (limite aplicado em runtime ou restart
  pendente);
- `core.db` escrito com `core-db-dsn` configurado;
- processo ou comando de status ausente;
- aumento de `RcvbufErrors`, `drop_requests` e diálogos com falha entre `antes` e `depois`.

Limitações: o `media_timeout` definido no dialplan ou no Lua não aparece; as portas UDP na faixa RTP
são contadas por servidor (no `.163`, OpenSIPS e FS dividem a máquina).
