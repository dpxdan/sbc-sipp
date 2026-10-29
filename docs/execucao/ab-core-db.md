# A/B do core db dos FreeSWITCH

Etapa 1 do caminho para mais CPS: descobrir qual fila segura o sistema entre 20 e 25 CPS e confirmar a
causa trocando o core db do nó suspeito. Na escada de 27/10/2026, o INVITE -> 200 ficou em ~160 ms em
20 CPS e subiu sem parar em 25 CPS, com CPU sobrando em todos os servidores.

| Nó | Core db hoje | Indício |
|---|---|---|
| `.163` | MySQL no PXC (`core-db-dsn` FLUX) | Em 25-30 CPS, `fs_calls` (tabela `calls` do core db) chegou a 467 com 341 sessões, e 389 linhas sobraram depois da carga: as escritas ficam para trás |
| `.162` | SQLite em disco (`/var/lib/freeswitch/db/core.db`) | No `stfc-c5000`, o atraso cresce com as simultâneas e se concentra no atendimento da perna A |

Sucesso: depois da troca, a mesma escada passa de 26 CPS com INVITE -> 200 p90 abaixo de 1 s, e o teto
passa a ser outro componente.

## Rodada A: escada fina instrumentada

Nada muda nos FS. Perfil `stfc-cps-escada-fina`: 16 a 26 CPS, +2 a cada 60 s, hold 10 s, ~12 min.

### Antes

Nos dois FS (`.163` e `.162`), e confira que o `sps` em uso subiu:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh aplicar 150 1300 && bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh mostrar
```

No `.165`, o guard de atraso precisa estar ligado:

```bash
grep -E '^GUARD_MAX_PDD_MS=' /etc/flux-loadtest/loadtest.conf
```

Schema do core db no PXC, no `.163` (campo `Database` do DSN):

```bash
grep -A10 '^\[FLUX\]' /etc/odbc.ini
```

Foto do `performance_schema` no db1 (`.161`), somente leitura. Os contadores são acumulados desde a
partida do MySQL e dominados pelas consultas da interface web; o que interessa é o delta da escada, então
a foto guarda o identificador de cada consulta (`DIGEST`) para a subtração depois:

```bash
mysql -N -B -e "SELECT DIGEST, COUNT_STAR, SUM_TIMER_WAIT, LEFT(DIGEST_TEXT, 100) FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST IS NOT NULL" > /root/ps-antes.tsv
```

### Durante

Capturas, iniciadas antes do disparo e encerradas depois do fim da execução (Ctrl+C):

| Onde | Comando |
|---|---|
| `.165` | `tcpdump -i ens192 -nn -s0 -w /root/fina-gen.pcap 'udp port 5060 or udp port 5090'` |
| `.162` | `tcpdump -i ens192 -nn -s0 -w /root/fina-fs2.pcap 'udp port 5070'` |
| `.163` | `tcpdump -i lo -nn -s0 -w /root/fina-fs1.pcap 'udp port 5070'` |

No `.163`, o OpenSIPS e o FS ficam na mesma máquina: as duas pernas do FS (OpenSIPS -> FS e o bridge
FS -> OpenSIPS) passam pela `lo`, não pela `ens192`. Uma captura na `ens192` do `.163` com o mesmo
filtro só mostra a conversa do OpenSIPS com o FS do `.162`: serve como segunda visão do `.162`, mas o
`pdd-pcap.py --fs 200.159.177.163:5070` não acha nenhuma chamada nela. Confira o nome da interface do
`.162` e do `.165` com `ip -br addr`.

### Depois

Mesma consulta do `performance_schema`, gravando em `/root/ps-depois.tsv`. O delta entre as duas fotos,
ordenado pelo tempo total gasto na escada (execuções, segundos, média em ms e a consulta):

```bash
awk -F'\t' 'NR == FNR { n[$1] = $2; t[$1] = $3; next } { dn = $2 - n[$1]; dt = ($3 - t[$1]) / 1e12; if (dn > 0) printf "%9d %9.1f %8.2f  %s\n", dn, dt, dt * 1000 / dn, $4 }' /root/ps-antes.tsv /root/ps-depois.tsv | sort -k2 -nr | head -25
```

Divida as execuções pelo total de chamadas da escada para ter as consultas por chamada. Consultas da pilha
SIP (`sip_dialogs`, `sip_registrations`, `sip_presence`) com média alta apontam para presença no banco
(`manage-presence` com `odbc-dsn`) dentro da thread do perfil.

Leitura:

```bash
python3 /opt/flux-loadtest/deploy/stfc-completo/pdd-pcap.py /root/fina-gen.pcap --faixa 60
```

```bash
python3 /opt/flux-loadtest/deploy/stfc-completo/pdd-pcap.py /root/fina-fs1.pcap --fs 200.159.177.163:5070 --faixa 60
```

```bash
python3 /opt/flux-loadtest/deploy/stfc-completo/pdd-pcap.py /root/fina-fs2.pcap --fs 200.159.177.162:5070 --faixa 60
```

Nos CSVs da execução (`metrics/fs1.csv` e `metrics/fs2.csv`), compare `fs_calls` com `fs_sessions / 2`:
com o core db em dia, os dois andam juntos; `fs_calls` acima indica escritas atrasadas.

### Decisão

| Resultado da rodada A | Rodada B |
|---|---|
| Atraso no `.163` (trechos `atende` ou `dialplan`), `fs_calls` do fs1 descolando e statements do core db lentos no PXC | Trocar o core db do `.163` |
| Atraso no `.162` (trecho `atende`), sem descolar no fs1 | Trocar o core db do `.162` |
| Atraso nos dois nós | Trocar os dois, um por vez, com uma escada depois de cada troca |
| `trying` alto (fila do sofia-sip) ou `dialplan` alto nos dois nós | Não é o core db: investigar sofia-sip ou o roteamento Lua + MySQL antes do A/B |
| Nenhum FS com atraso interno, mas o total alto | Antes do FS: OpenSIPS ou `load_balancer` (A15) |

## Rodada B: troca do core db

Exige restart do FreeSWITCH do nó. Faça em janela de baixo tráfego, um nó por vez.

### Pré-requisito: quem lê o core db no PXC

Com o `.163` fora do PXC, as tabelas `channels` e `calls` do core db deixam de existir no banco
compartilhado. Antes, confirme que nenhum sistema depende delas (por exemplo, uma tela de chamadas
ativas da interface Flux). Fora de qualquer teste, se o `COUNT_STAR` de `SELECT` nessas tabelas cresce
entre duas fotos do `performance_schema`, alguém está lendo. O `.162` já grava em SQLite local, então
qualquer leitura no PXC hoje só enxerga as chamadas do `.163`.

### Mudança no `switch.conf.xml`

Arquivo: `/etc/freeswitch/autoload_configs/switch.conf.xml`. Confira os nomes dos parâmetros no arquivo
da versão instalada (1.11.3) antes de editar.

| Nó | De | Para |
|---|---|---|
| `.163` | `<param name="core-db-dsn" value="FLUX"/>` (ou o DSN em uso) | Comentar o `core-db-dsn` e acrescentar `<param name="core-db-name" value="/dev/shm/core.db"/>` |
| `.162` | SQLite em `/var/lib/freeswitch/db/core.db` | Acrescentar `<param name="core-db-name" value="/dev/shm/core.db"/>` |

O core db guarda só estado transitório (canais, chamadas, registros em memória): o FS recria as tabelas
na partida, e perder o arquivo num reboot não tem efeito. No `.162`, o mesmo restart aplica o
`sessions-per-second` 300 que já está no arquivo.

### Procedimento, por nó

1. Identifique o destino do nó no `load_balancer` (no `.163`):

    ```bash
    opensips-cli -x mi lb_list
    ```

2. Desabilite o destino para drenar o nó. Novas chamadas vão para o outro FS:

    ```bash
    opensips-cli -x mi lb_status ID_DO_DESTINO 0
    ```

3. Acompanhe as chamadas do nó até zerar ou até o limite de espera combinado. As que restarem caem no
   restart:

    ```bash
    watch -n 5 "fs_cli -x 'show calls count'"
    ```

4. Backup e edição do `switch.conf.xml`:

    ```bash
    cp -a /etc/freeswitch/autoload_configs/switch.conf.xml /etc/freeswitch/autoload_configs/switch.conf.xml.$(date +%Y%m%d-%H%M%S)
    ```

5. Restart do FreeSWITCH (derruba as chamadas ativas do nó):

    ```bash
    systemctl restart freeswitch
    ```

6. Verificação:

    ```bash
    systemctl status freeswitch --no-pager && fs_cli -x status && ls -la /dev/shm/core.db
    ```

    ```bash
    bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh mostrar
    ```

    No `.165`: `./flux-loadtest.sh capacidade -c /etc/flux-loadtest/loadtest.conf --label depois-core-db`
    (`fs_cfg_core_db` = `sqlite` no nó trocado) e `./flux-loadtest.sh smoke -c /etc/flux-loadtest/loadtest.conf`.

7. Reabilite o destino:

    ```bash
    opensips-cli -x mi lb_status ID_DO_DESTINO 1
    ```

8. Repita a rodada A (mesmo perfil, mesmas capturas), de preferência no mesmo horário de tráfego.

### Reversão

Drene o nó (passos 1 a 3), restaure o backup do `switch.conf.xml`, reinicie o FreeSWITCH, verifique
(passo 6) e reabilite o destino.

## Comparação

| Medida | Rodada A | Rodada B |
|---|---|---|
| Último degrau com total p90 abaixo de 1 s e falha 0 | | |
| Degrau em que o guard parou | | |
| `atende` p90 no nó trocado, por degrau | | |
| `fs_calls` contra `fs_sessions / 2` no nó trocado | | |
| UPDATE/s no db1 por CPS (`db_update_s`) | | |

Se o teto passar de 26 CPS, rode a `stfc-cps-escada50` para achar o próximo limite. Se não mudar, o
core db não era a fila: o resultado da rodada A indica o próximo suspeito.
