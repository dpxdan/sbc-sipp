# Degraus e perfis

## Contas básicas

| Grandeza | Conta |
|---|---|
| Simultâneas em regime | CPS x hold |
| Sessões no sistema | simultâneas x 2 (perna A + perna B) |
| Sessões no FS mais carregado | simultâneas x 2 x ~0,55 (o `load_balancer` não divide meio a meio) |
| `max-sessions` recomendado por FS | 1,4 x simultâneas |
| Sessões por segundo (`sps`) por FS | CPS x 2 x ~0,55 |
| Limite de simultâneas do SIPp (`-l` padrão) | CPS x (hold + 4) x 1,2 |
| Portas RTP | 2 por perna com mídia (com `bypass_media = 0`, 2 pernas por chamada) |

Exemplo: 30 CPS com hold de 30 s dá ~900 simultâneas, ~1800 sessões, ~33 `sps` e ~1000 sessões no
FS mais carregado.

## Degraus das metas da issue

| Simultâneas | 100 CPS | 200 CPS | 300 CPS |
|---|---|---|---|
| 1000 | `-r 100 -H 10` | `-r 200 -H 5` | `-r 300 -H 4` |
| 2000 | `-r 100 -H 20` | `-r 200 -H 10` | `-r 300 -H 7` |
| 3000 | `-r 100 -H 30` | `-r 200 -H 15` | `-r 300 -H 10` |

Use `-w` de pelo menos `hold + 120` e uma janela que cubra a rampa, e suba **um degrau por
execução**, comparando os relatórios.

!!! tip "Separe CPS de simultâneas"
    Para medir simultâneas sem misturar com o atraso de CPS, mantenha o CPS baixo (10) e aumente o
    hold: é o que fazem os perfis `stfc-c1000`, `stfc-c3000` e `stfc-c5000`. Para medir CPS, use um
    hold que mantenha as simultâneas longe do `max-sessions` (perfil `stfc-cps30`).

## Limites do FreeSWITCH em runtime: `fs-limites.sh`

Os FS do STFC estão com limites que não comportam os degraus maiores. O `fs-limites.sh` sobe os
limites em runtime (`fsctl sps` e `fsctl max_sessions`), sem restart e sem alterar o `switch.conf`.
Rode como root **nos dois FS**:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh mostrar
```

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh aplicar 150 4200
```

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh restaurar
```

- `aplicar SPS MAX_SESSOES` nunca reduz um limite: usa o maior entre o pedido e o atual.
- Os valores anteriores ficam em `/root/flux-loadtest-fs-limites.antes`; `restaurar` volta a eles.
- Um restart do FS também volta ao `switch.conf`.

Cerca de 30 s depois de aplicar, confira no OpenSIPS que o `max` dos dois nós subiu. Sem isso, o
OpenSIPS responde 503 antes do FS:

```bash
opensips-cli -x mi lb_list | grep -E '"(uri|max|load)"'
```

O `max` do `lb_list` não é fixo: o OpenSIPS o recalcula com o que o FS publica (sessões e CPU
ociosa). Sem carga, fica perto de `max_sessions` x CPU ociosa; sob carga, cai.

!!! danger "Limites maiores valem também para clientes"
    Com limites maiores, o FS aceita mais chamadas, do teste e reais. Quando o FS chega ao
    `max-sessions`, ele responde `503 Maximum Calls In Progress` **também para as chamadas reais**,
    até o guard parar o teste. Restaure ao fim da janela.

## Perfis do STFC

Ficam em `deploy/stfc-completo/profiles/` e são disparados pelo menu do Zabbix ou à mão (as chaves
equivalem às opções do `run`).

| Perfil | Carga | Duração | `fs-limites.sh aplicar` (nos 2 FS) |
|---|---|---|---|
| `stfc-piloto` | 10 CPS por 60 s, hold 10 s | ~6 min | — |
| `stfc-cps20` | 10 a 20 CPS em 40 s (+5 a cada 20 s), janela 240 s, hold 20 s | ~9 min | — |
| `stfc-cps30` | 10 a 30 CPS em 80 s (+5 a cada 20 s), ~220 s em 30 CPS, hold 30 s (~900 simultâneas) | ~10 min | `150 1300` |
| `stfc-cps-escada50` | Escada de 10 a 50 CPS (+5 a cada 60 s), mais 120 s em 50, hold 10 s (~600 simultâneas) | ~16 min | `150 1300` |
| `stfc-cps-escada-fina` | Escada de 16 a 26 CPS (+2 a cada 60 s), mais 60 s em 26, hold 10 s (~300 simultâneas) | ~12 min | `150 1300` |
| `stfc-c1000` | 1000 simultâneas a 10 CPS (janela 150 s, hold 100 s) | ~9 min | — |
| `stfc-c1000-rtp` | Igual ao `stfc-c1000`, com `MEDIA=rtp` (G.711 nos dois sentidos) | ~9 min | — |
| `stfc-c2000` | 2000 simultâneas a 10 CPS (janela 320 s, hold 200 s, 120 s no patamar, `-l` 2448) | ~13 min | `150 2800` |
| `stfc-c3000` | 3000 simultâneas a 10 CPS (janela 420 s, hold 300 s, 120 s no patamar, `-l` 3648) | ~16 min | `150 4200` |
| `stfc-c5000` | 5000 simultâneas a 10 CPS (janela 620 s, hold 500 s, 120 s no patamar, `-l` 6048) | ~23 min | `150 7000` |

Durações com o baseline e o cooldown de 120 s do `loadtest.conf` do STFC. Todos com `MEDIA=none`,
exceto o `stfc-c1000-rtp`: rodado logo depois do `stfc-c1000`, o par mostra o custo da mídia nos FS
na mesma carga. Ele exige DIDs com `bypass_media = 0` (veja [Conta e DIDs de teste](../instalacao/massa-dids.md))
e coloca ~180 Mbit/s por sentido no gerador.

Ordem recomendada: `stfc-piloto` -> `stfc-c1000` -> `stfc-c2000` -> `stfc-c3000` -> `stfc-c5000` (só depois de um
`stfc-c3000` sem falhas) e, separadamente, `stfc-cps20` -> `stfc-cps30` -> `stfc-cps-escada50`
(e a `stfc-cps-escada-fina` em volta do teto encontrado).

Antes de perfis longos, tire uma foto de capacidade com o hold planejado. Ela alerta timeout de mídia
menor que o hold (com `MEDIA=none` não há RTP e as chamadas cairiam), memória, threads e portas RTP:

```bash
./flux-loadtest.sh capacidade -c /etc/flux-loadtest/loadtest.conf --hold 500 --label antes-c5000
```

Conferências manuais equivalentes:

| Item | Comando | Referência da campanha |
|---|---|---|
| Memória | `free -g` | 2,2 GB no FS com 2000 sessões; projeta ~6 GB com 5500 |
| Threads | `systemctl show freeswitch -p TasksMax,LimitNPROC` e `sysctl kernel.threads-max` | ~1 thread por sessão (2024 com 2000) |
| Portas RTP | `grep -E 'rtp-(start\|end)-port' /etc/freeswitch/autoload_configs/switch.conf.xml` | Padrão 16384-32768 (~8 mil sessões RTP) |
| Timeout de mídia | `grep -rE 'rtp-timeout-sec\|media_timeout' /etc/freeswitch` | Precisa ser maior que o hold com `MEDIA=none` |
| Memória do OpenSIPS | `opensips-cli -x mi get_statistics shmem:` | 21,7% com 1962 diálogos |

## Encontrar o limite de CPS

Objetivo: o maior CPS com atraso aceitável e o componente que limita. O degrau de 21/10 misturou CPS
com chamadas simultâneas (hold longo), e o atraso do `.162` cresce com as simultâneas. Por isso a escada
usa hold de 10 s: simultâneas ≈ CPS x (10 s + PDD), ~600 em 50 CPS.

Em produção, o atraso atinge também as chamadas reais, sem gerar falha SIP. Use `GUARD_MAX_PDD_MS=2000`
no `loadtest.conf`: o guard para a carga quando o INVITE -> 200 médio do período passa de 2 s por
`GUARD_HITS` amostras seguidas, e o patamar em que ele parou é o limite.

### 1. Escada até 50 CPS pelo OpenSIPS

Perfil `stfc-cps-escada50`, pelo menu do Zabbix ou à mão. Antes, nos dois FS:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh aplicar 150 1300
```

Durante toda a janela, capture no gerador e no `.162`:

```bash
tcpdump -i ens192 -nn -s0 -w /root/escada-gen.pcap 'udp port 5060 or udp port 5090'
```

```bash
tcpdump -i ens192 -nn -s0 -w /root/escada-fs2.pcap 'udp port 5070'
```

Leitura, com faixas de 60 s iguais aos patamares:

```bash
python3 /opt/flux-loadtest/deploy/stfc-completo/pdd-pcap.py /root/escada-gen.pcap --faixa 60
```

```bash
python3 /opt/flux-loadtest/deploy/stfc-completo/pdd-pcap.py /root/escada-fs2.pcap --fs 200.159.177.162:5070 --faixa 60
```

| Resultado | Leitura |
|---|---|
| Último patamar com total p90 abaixo de 1 s e falha 0 | CPS sustentável |
| Patamar em que o guard parou | Limite (atraso ou falha) |
| Total p90 muito maior em um FS | O nó limita; o modo `--fs` mostra o trecho dentro dele |
| Problema na página Gargalos no horário do patamar | Componente que passou do limite (CPU do `.163`, banco, `load_balancer`) |

Depois, nos dois FS: `fs-limites.sh restaurar`.

### 2. Acima de 50 CPS

Só se a escada chegar a 50 CPS sem degradar. O menu do Zabbix recusa perfis acima de `ZBX_MAX_CPS`
(50), então o disparo é pela linha de comando, depois de `fs-limites.sh aplicar 250 2000` nos dois FS:

```bash
./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip -r 100 --cps-start 50 --ramp-step 10 --ramp-interval 60 -w 480 -H 10 -M none --label stfc-cps-escada100
```

### 3. Isolar o nó, sem OpenSIPS

Com o limite encontrado, repita a escada direto em cada FS ([FreeSWITCH direto](fs-direto.md)):
`SIP_TARGET` no IP:5070 do nó e o gerador liberado no `acl_lb_networks` dele.

| Resultado | Limite |
|---|---|
| `.163` sozinho sustenta mais que o sistema e o `.162`, menos | `.162` |
| Os dois sozinhos sustentam mais que o sistema | OpenSIPS ou `load_balancer` (A15) |
| Os dois param no mesmo ponto | Componente comum: banco ou gerador |

### 4. Core db dos FS

Na escada de 27/10/2026 o teto ficou entre 20 e 25 CPS, com CPU sobrando e sinais de fila no core db
(`fs_calls` do `.163` acima das sessões). O roteiro completo está em [A/B do core db](ab-core-db.md):
escada fina (`stfc-cps-escada-fina`) com captura no gerador e nos dois FS, decisão por nó e troca do
core db (SQLite em tmpfs), com drenagem pelo `load_balancer`, restart e reversão.

## Criar um perfil

```
# /etc/flux-loadtest/profiles.d/meu-perfil.conf
DESC="Descricao curta que aparece no menu do Zabbix"
ZABBIX_ENABLED=1
TESTS=sip
CPS=10
CPS_START=
RAMP_STEP=
RAMP_INTERVAL=
WINDOW=300
CALLS=
HOLD=20
MEDIA=none
LABEL=meu-perfil
```

- Nome do arquivo = nome do perfil: `[a-z0-9-]`, até 32 caracteres.
- Chave vazia = padrão do `flux-loadtest.sh`.
- `CPS` e `WINDOW` não podem passar de `ZBX_MAX_CPS` e `ZBX_MAX_WINDOW` (`zabbix-runner.conf`).
- Depois de criar ou alterar um perfil, rode de novo o `flux-host.sh prepare zabbix-agent` e o
  `zabbix setup --scripts` (veja [Zabbix](../configuracao/zabbix.md#5-disparo-de-perfis-pelo-menu-do-zabbix)).
