# VM de teste (gerador)

A VM de teste roda o `flux-loadtest.sh`, os dois SIPp (originador e atendedor), o `wrk` e,
opcionalmente, o `sysbench`. Ela também roda o coletor local (linhas `gen` do relatório).

## Requisitos

| Item | Requisito |
|---|---|
| Sistema | Debian 12 (bash 5, `/proc`, `ip`) |
| Pacotes | `sip-tester` (SIPp 3.6.1), `wrk`, `openssh-client`, `curl`, `python3` |
| Opcional | `sysbench` e `default-mysql-client` (só para `--tests mysql`) |
| Usuário | root, ou um usuário com escrita em `RESULTS_DIR` e `/etc/flux-loadtest` |
| Rede | SSH até todos os servidores; UDP até o destino SIP; HTTPS até o servidor web |
| Relógio | NTP/chrony ativo: os timestamps vêm de cada servidor |

## Instalação recomendada: `flux-host.sh prepare gen`

Instala os pacotes, grava os sysctl de buffers UDP e o limite de arquivos abertos. Não instala
nem reinicia serviços.

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

Revise o plano (nada é alterado):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare gen --dry-run
```

Aplique (pede a palavra `SIM`):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare gen
```

Arquivos gravados pelo papel `gen`:

| Arquivo | Conteúdo |
|---|---|
| `/etc/sysctl.d/90-flux-loadtest.conf` | Buffers UDP (`rmem_max` e afins) |
| `/etc/security/limits.d/90-flux-loadtest.conf` | Arquivos abertos (`nofile`) |

Backup do estado anterior em `/var/backups/flux-loadtest/<data>/`.

## Instalação manual

Pacotes:

```bash
apt install sip-tester wrk openssh-client curl python3
```

Só para `--tests mysql`:

```bash
apt install sysbench default-mysql-client
```

Permissões dos scripts (se o repositório foi copiado em vez de clonado):

```bash
chmod +x /opt/flux-loadtest/flux-loadtest.sh /opt/flux-loadtest/lib/collector.sh /opt/flux-loadtest/lib/flux_zabbix.py
```

## Diretórios de configuração e resultados

```bash
install -d -m 0700 /etc/flux-loadtest
```

```bash
install -d -m 0750 /var/lib/flux-loadtest/results
```

Configuração inicial a partir do exemplo:

```bash
install -m 0640 /opt/flux-loadtest/loadtest.conf.example /etc/flux-loadtest/loadtest.conf
```

No STFC, use o arquivo já preenchido do runbook:

```bash
install -m 0640 /opt/flux-loadtest/deploy/stfc-completo/loadtest.conf /etc/flux-loadtest/loadtest.conf
```

Confira a ajuda:

```bash
/opt/flux-loadtest/flux-loadtest.sh --help
```

O `loadtest.conf` é descrito em [loadtest.conf](../configuracao/loadtest-conf.md). A lista de
DIDs (`DID_FILE`) é gerada em [Conta e DIDs de teste](massa-dids.md).

## Firewall da VM

Se a política de entrada da VM for `drop`, libere **vindo dos FreeSWITCH**:

| Porta | Uso |
|---|---|
| `SIP_LOCAL_PORT`/udp (5060) | Respostas do OpenSIPS ao originador |
| `UAS_PORT`/udp (5090) | INVITE do bridge para o atendedor |
| `RTP_PORT_BASE` em diante (20000+) | RTP do originador, 2 portas por chamada |
| `UAS_RTP_PORT_BASE` em diante (40000+) | RTP do atendedor, 2 portas por chamada |

Anote as regras criadas para a reversão.

## Dimensionamento

Estimativa para o pior caso da issue (3000 simultâneas, 300 CPS, `--media rtp`). Confirme com as
linhas `gen` do relatório de cada degrau.

| Recurso | Estimativa |
|---|---|
| CPU | 8 vCPU: dois SIPp com a sinalização em ~1 núcleo cada, mais as threads de RTP |
| Memória | 8 GB |
| Rede | 1 Gbps: 2 x 3000 fluxos G.711 x ~90 kbit/s = ~540 Mbit/s por sentido, ~300 mil pps |
| Arquivos abertos | `ulimit -n` de pelo menos 3 x simultâneas por SIPp (o script tenta elevar para 65536) |

Com `--media none` a VM precisa de muito menos: no piloto a 1 CPS, o SIPp usou ~4% de um núcleo.

!!! warning "Gerador saturado invalida o teste"
    Se a CPU da VM ou a thread do SIPp chegar perto de 100%, os números deixam de representar os
    servidores. `GUARD_MAX_GEN_CPU_PCT` interrompe o teste nesse caso. Veja
    [Como interpretar](../resultados/como-interpretar.md#1-a-execucao-e-valida).
