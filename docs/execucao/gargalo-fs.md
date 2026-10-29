# Gargalo do FS .162

Roteiro para descobrir, confirmar e remover o teto de CPS do FreeSWITCH do `.162`. É ele que segura o
sistema em 20 a 25 CPS: o `load_balancer` divide as chamadas meio a meio, então o sistema para no dobro do
teto do nó mais lento.

## Sintoma

Nas escadas de 28/10/2026 (`stfc-cps-escada-fina` às 22:51 e `stfc-cps-escada50` às 23:29), com o core db
em SQLite nos dois FS:

| Medida | `.163` | `.162` |
|---|---|---|
| Mensagens SIP enviadas pelo FS, no fim da escada | acompanham as recebidas, até 91/s | param em 84 a 86/s; as recebidas sobem para 95 a 114/s |
| `trying` p90 a ~12,5 CPS por nó | 12 ms | 831 ms |
| `total` p90 a ~12,5 CPS por nó | 118 ms | 4,9 s |
| INVITE retransmitidos pelo OpenSIPS | 0 | 333 |
| 200 da perna B retransmitidos (ACK atrasado) | 0 | 699 |
| CPU do processo FreeSWITCH | ~185% | ~105% |
| Thread mais carregada | ~13% | ~10% |

Leitura:

- O `.162` tem um **teto fixo de vazão**: ~84 mensagens por segundo, ou ~12 chamadas por segundo
  (cerca de 7 mensagens enviadas por chamada). Isso equivale a ~80 ms **serializados** por chamada. A
  10 CPS por nó ele já fica ~85% ocupado, e a fila começa.
- Não há pausas longas no envio: o FS trabalha sem parar, mas não passa desse ritmo.
- CPU, disco e core db estão fora: o host fica ocioso, nenhuma thread satura e o teto não mudou com o
  core db em `/dev/shm`.
- O dialplan (Lua + MySQL) não piora com a carga: a diferença entre `dialplan` p90 e `trying` p90 fica em
  ~100 ms em todas as faixas. A fila está na camada sofia, antes do 100 Trying e antes do 200 da perna A.

Para repetir a contagem em outra captura do FS, com `T0` igual ao início da fase `sip` (`phases.tsv`):

```bash
tshark -r fina-fs2.pcap -T fields -e frame.time_epoch -e udp.srcport | awk -v t0=T0 '{ s = int($1 - t0); if (s < 0) next; w = int(s / 30) * 30; if ($2 == 5070) tx[w]++; else rx[w]++ } END { for (w = 0; w <= 600; w += 30) if (tx[w] + rx[w]) printf "%4d-%-4d tx/s=%5.1f rx/s=%5.1f\n", w, w + 30, tx[w] / 30, rx[w] / 30 }'
```

`tx` é o que o FS envia (porta de origem 5070). Quando `tx` para de subir e `rx` continua, o nó saturou.

## Hipótese

O perfil `default` tem `manage-presence=true` e `odbc-dsn=$${dsn}`: a presença fica no PXC. No delta do
`performance_schema` da escada50, cada chamada fez:

| Grupo | Consultas por chamada | Tempo no db1 por chamada |
|---|---|---|
| Presença e registro (`sip_dialogs`, `sip_subscriptions`, `sip_registrations`) | ~19 | ~32 ms |
| `SET max_execution_time` + `SELECT ?` | ~41 pares | ~11 ms |
| Billing e roteamento (`cdrs`, `dids`, `accounts`, `pricelists`...) | ~15 | ~15 ms |

- As consultas de presença rodam na camada sofia. Pelo que se sabe do código do mod_sofia (a confirmar com
  o backtrace da etapa 3), as escritas síncronas do perfil passam por um mutex único: ficam
  serializadas em cada nó.
- Os pares `SET max_execution_time` + `SELECT ?` parecem acompanhar cada consulta ODBC, o que daria ~3
  idas e voltas por consulta. A origem ainda não está confirmada.
- Conta: ~32 ms de execução no banco mais ~57 idas e voltas. Com RTT de ~0,9 ms até o db1, isso fecha os
  ~80 ms por chamada do `.162`. Um RTT menor no `.163` deixaria o custo abaixo do limite a 12,5 CPS.

Para 300 CPS (~150 por nó), o custo serializado por chamada precisa ficar abaixo de 7 ms. Com presença no
banco isso não é possível em nenhum dos nós: corrigir só o RTT do `.162` levaria o sistema a ~40 CPS.

## Etapa 1: diagnóstico

Somente leitura. O `deploy/stfc-completo/diag-fs-gargalo.sh` roda no `.165` e consulta de uma vez todos os
FS (`FS_HOSTS`) e bancos (`DB_HOSTS`) por SSH, com a mesma configuração do flux-loadtest. O resultado vai
para um arquivo Markdown.

| Onde | O que coleta |
|---|---|
| Cada FS | `manage-presence`, `odbc-dsn` e parâmetros de presença do perfil `default`; core db e limites do `switch.conf`; seção do DSN no `/etc/odbc.ini`; driver ODBC e pacotes; RTT até o servidor do DSN e até cada banco; custo de uma consulta pelo caminho ODBC do FS (`isql`) |
| Cada banco | instruções e tempo por host cliente (`performance_schema`) |
| Primeiro banco | linhas de `sip_subscriptions`, `sip_dialogs`, `sip_presence` e `sip_registrations` por hostname |

As senhas do DSN e do `odbc.ini` saem mascaradas. Carga gerada: ping de 5 pacotes/s e 2000 `SELECT 1` por
FS; no banco, leituras do `performance_schema`.

### Foto, sem carga

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/diag-fs-gargalo.sh -o /root/diag-fs-ocioso.md
```

### Junto com a escada

Com `--janela`, o script tira uma segunda foto do `performance_schema` no fim da janela e mostra o delta
por host cliente e por consulta. Com `--sob-carga`, os FS repetem ping e `isql` naquele instante e
registram as chamadas e as threads do FreeSWITCH com mais CPU.

Para a `stfc-cps-escada50` (baseline de 120 s; degrau de 25 CPS entre 300 e 360 s), inicie o script e
dispare a escada logo depois. A medição ociosa cai no baseline:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/diag-fs-gargalo.sh --janela 420 --sob-carga 330 -o /root/diag-fs-escada50.md
```

Opções:

| Opção | Padrão | Uso |
|---|---|---|
| `-c ARQUIVO` | `/etc/flux-loadtest/loadtest.conf` | configuração do flux-loadtest |
| `-o ARQUIVO` | `./diag-fs-AAAAmmdd-HHMMSS.md` | resultado; não sobrescreve um arquivo existente |
| `--janela SEG` | 0 (só foto acumulada) | delta do `performance_schema` |
| `--sob-carga SEG` | metade da janela | instante da medição sob carga |
| `--ping N` | 200 | pacotes por alvo na medição ociosa |
| `--consultas N` | 2000 | `SELECT 1` pelo `isql` na medição ociosa |
| `--schema NOME` | `FLUX_DB_NAME` | schema das tabelas `sip_*` |

Saída 0: todos os servidores responderam. Saída 5: algum falhou, com o motivo no arquivo.

### Permissões

O script usa o usuário SSH do flux-loadtest (`loadtest`), com `sudo -n` só para o `fs_cli`, e o
`MYSQL_CLI_CMD` nos bancos. Se uma seção vier com erro de permissão, rode o comando equivalente como root
no servidor:

| Seção com erro | Comando como root |
|---|---|
| `odbc.ini ilegivel` | `grep -A15 '^\[FLUX\]' /etc/odbc.ini` (mascare a senha antes de compartilhar) |
| `isql` falha por credencial | o comando de `isql` abaixo da tabela; divida o `real` por 2000 |
| `performance_schema` negado | `mysql -N -B -e "SELECT HOST, SUM(COUNT_STAR), SUM(SUM_TIMER_WAIT) FROM performance_schema.events_statements_summary_by_host_by_event_name GROUP BY HOST"` |
| Tabelas `sip_*` negadas | `mysql -N -B -e "SELECT hostname, COUNT(*) FROM sip_subscriptions GROUP BY hostname" flux` |

```bash
time (for i in $(seq 2000); do echo 'SELECT 1'; done | isql -b FLUX > /dev/null)
```

Troque `FLUX` pelo nome do DSN em uso (campo DSN do resumo).

### Leitura

| Resultado | Conclusão |
|---|---|
| RTT ou `isql` (ms por consulta) maior no `.162` | Cada consulta síncrona do perfil custa mais nesse nó; o teto de ~12 CPS vem dessa espera. Investigue o caminho de rede até o db1 (VLAN, switch virtual, offload da placa) |
| DSN, servidor, driver ou opções do `odbc.ini` diferentes entre os FS | A diferença de caminho até o banco explica a assimetria; alinhe o `.162` com o `.163` |
| `manage-presence` `true` nos dois e `sip_subscriptions` vazia ou só com lixo | A presença não é usada: siga para a etapa 2 |
| `sip_subscriptions` com assinaturas reais (BLF de ramais) | Avalie quem depende de presença antes da etapa 2 |
| Delta por host: mais tempo por execução no `.162`, com o mesmo tipo de carga | O `.162` espera mais pelo banco |
| Nada diferente entre os nós | Siga para a etapa 3 (backtrace) |

## Etapa 2: correção

`manage-presence=false` no `sip_profile` `default`, compartilhado pelos dois FS pela tabela
`sip_profiles`. Sem presença, o FS deixa de gravar `sip_dialogs` e de atualizar `sip_subscriptions` a cada
chamada.

Impacto:

- altera o perfil SIP em uso pelos dois FS;
- exige restart do perfil em cada nó, o que derruba as chamadas e os registros daquele nó (os registros
  voltam no próximo refresh dos aparelhos);
- desliga BLF, presença e SLA para todos os ramais do perfil.

Não remova o `odbc-dsn`: a consulta de roteamento lê `sip_registrations` no banco compartilhado. Com o
perfil em SQLite local, um nó deixaria de ver os registros do outro.

Procedimento, em janela de baixo tráfego:

1. Rode a etapa 1 e guarde o arquivo (estado antes).
2. Altere `manage-presence` para `false` no perfil `default`, pela interface do Flux (ou no JSON da tabela
   `sip_profiles`). Guarde o valor anterior.
3. Para cada FS, um por vez: drene o nó pelo `load_balancer` (passos 1 a 3 da
   [Rodada B do A/B do core db](ab-core-db.md#procedimento-por-no)), reinicie o perfil e reabilite o
   destino.

    ```bash
    fs_cli -x 'sofia profile default restart'
    ```

4. Confira, em cada nó, que o perfil subiu com o valor novo:

    ```bash
    fs_cli -x 'sofia status profile default' | grep -E '^(STATE|PRES-HOSTS)'
    ```

    ```bash
    fs_cli -x 'xml_locate configuration configuration name sofia.conf' | grep -E 'name="manage-presence"'
    ```

5. Repita a `stfc-cps-escada50` com as capturas do [A/B do core db](ab-core-db.md#durante) e o
   diagnóstico junto (`--janela 420 --sob-carga 330`).

Resultado esperado:

- `sip_dialogs` e `sip_subscriptions` somem do delta por consulta;
- as mensagens enviadas pelo `.162` acompanham as recebidas, sem teto em ~84/s;
- `trying` p90 do `.162` perto de 10 ms a 12,5 CPS por nó;
- o guard passa do degrau de 25 CPS, e o próximo teto aparece.

Reversão: volte `manage-presence` ao valor anterior e repita o passo 3.

## Etapa 3: backtrace

Só se a etapa 2 não mudar o teto. O backtrace de todas as threads do FreeSWITCH, tirado durante a
saturação, mostra onde as threads do sofia esperam: mutex, `SQLExecDirect` ou `recv`.

Impacto: congela o FreeSWITCH por 1 a 5 s e exige os símbolos de debug instalados. Só em janela de teste,
no degrau em que o `.162` satura.

```bash
gdb -p "$(pidof freeswitch)" -batch -ex 'set pagination off' -ex 'thread apply all bt 15' > /root/bt-fs2.txt 2>&1
```

```bash
grep -cE 'sofia_glue_actually_execute_sql|switch_cache_db_execute_sql' /root/bt-fs2.txt
```

```bash
grep -oE 'in (pthread_mutex_lock|__lll_lock_wait|SQLExecDirect|recv|poll|epoll_wait)' /root/bt-fs2.txt | sort | uniq -c | sort -nr
```

Muitas threads do sofia em `pthread_mutex_lock` ou `__lll_lock_wait`, abaixo de
`sofia_glue_actually_execute_sql`, confirmam a fila no mutex do perfil. Threads em `recv` abaixo do driver
ODBC indicam espera pelo banco.
