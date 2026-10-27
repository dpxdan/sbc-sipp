# flux-loadtest — teste de carga do FluxSBC (WEB-1437)

Ferramenta de teste de carga executada a partir de uma **VM separada** (VM de teste), que atua nos
servidores do FluxSBC por SSH. Ela gera carga SIP (INVITE para DIDs), carga HTTP (nginx + PHP-FPM)
e, opcionalmente, carga no MySQL, enquanto monitora CPU, memória, rede, disco e métricas de cada
serviço em todos os servidores. O resultado é um relatório `.txt` por execução, com os dados brutos
ao lado, e opcionalmente o envio ao Zabbix.

```
VM de teste --INVITE:5060--> OpenSIPS (sbc-stfc-1) --load_balancer--> FS1 :5070 (sbc-stfc-1)
     |                                                          \--> FS2 :5070 (sbc-stfc-02)
     |<--INVITE:5090 + RTP do FS (DIDs DIRECT-IP, atendedor)            |
     |--wrk--> nginx -> PHP-FPM 7.3 (sbc-stfc-interfaceweb)             v
     |                         \------------------------> VIP 172.17.4.100 (keepalived)
     |--sysbench (opcional, rede interna) --------------->   Percona XtraDB Cluster
     +--ssh (coletor /proc) --> todos os servidores
```

## Documentação

A documentação completa (instalação, configuração, execução e **interpretação dos resultados por
equipe**) está em `docs/`, no formato MkDocs:

```bash
python3 -m venv .venv && . .venv/bin/activate && pip install -r docs/requirements.txt
```

```bash
mkdocs serve
```

| Assunto | Página |
|---|---|
| Arquitetura e ambiente STFC | [`docs/arquitetura.md`](docs/arquitetura.md) |
| Instalação da VM de teste e dos servidores | [`docs/instalacao/`](docs/instalacao/vm-teste.md) |
| `loadtest.conf`, chaves SSH, Zabbix | [`docs/configuracao/`](docs/configuracao/loadtest-conf.md) |
| Fluxo de um teste, comandos, degraus | [`docs/execucao/`](docs/execucao/fluxo.md) |
| Como interpretar os resultados | [`docs/resultados/como-interpretar.md`](docs/resultados/como-interpretar.md) |
| Leitura por equipe | [`docs/resultados/por-equipe.md`](docs/resultados/por-equipe.md) |
| Solução de problemas | [`docs/referencia/solucao-de-problemas.md`](docs/referencia/solucao-de-problemas.md) |

## Arquivos

| Arquivo | Função |
|---|---|
| `flux-loadtest.sh` | Orquestrador. Ações: `keys`, `check`, `smoke`, `run`, `report`, `zabbix`, `capacidade` |
| `lib/collector.sh` | Coletor de métricas enviado por SSH (`bash -s`); lê `/proc` e comandos de status |
| `lib/capacidade.sh` | Foto de limites e uso de cada servidor (antes, pico e depois do teste) |
| `lib/flux_zabbix.py` | Envio ao Zabbix por trapper e provisionamento dos hosts pela API |
| `zabbix/` | Templates do Zabbix 7.2 (gerados por `gen_templates.py`; não editar o YAML à mão) |
| `scenarios/` | Cenários SIPp: originador (`uac-did.xml.in`) e atendedor (`uas-answer.xml.in`) |
| `bin/flux-loadtest-zbx` | Disparo de perfis pelo Zabbix, chamado pelo zabbix-agentd |
| `profiles/` | Perfis de teste e `zabbix-runner.conf` de exemplo |
| `loadtest.conf.example`, `dids.txt.example` | Configuração comentada e formato do arquivo de DIDs |
| `install/` | `flux-host.sh`: `prepare` em servidores existentes, `lab` em servidores novos |
| `lab/` | Laboratório STFC em Docker (`lab.sh`) ou em VMs (`lab/vm/vmlab.sh`) |
| `deploy/stfc-completo/` | Runbook, SQL, scripts e resultados da campanha no STFC |

## Início rápido

Na VM de teste (Debian 12), como root:

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare gen
```

```bash
install -d -m 0700 /etc/flux-loadtest && install -m 0640 /opt/flux-loadtest/loadtest.conf.example /etc/flux-loadtest/loadtest.conf
```

Edite o `loadtest.conf`, prepare os servidores e os DIDs de teste (veja `docs/instalacao/`) e siga a
ordem abaixo. Cada passo valida o anterior.

| Objetivo | Comando |
|---|---|
| Preparar as chaves SSH | `./flux-loadtest.sh keys setup --via admin --write-config` |
| Validar o ambiente (somente leitura) | `./flux-loadtest.sh check --fs-password` |
| Uma chamada de teste | `./flux-loadtest.sh smoke --media none` |
| Ver o plano sem executar | `./flux-loadtest.sh run --dry-run -t sip,web,mysql -r 20 -H 20 -w 300` |
| Piloto SIP | `./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 1 -H 10 -w 60 --media none --label piloto` |
| Todos os testes | `./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 20 -H 20 -w 300 --label todos` |
| Foto de capacidade | `./flux-loadtest.sh capacidade --hold 300 --label antes` |
| Regenerar relatório | `./flux-loadtest.sh report <diretorio-da-execucao>` |
| Remover as chaves | `./flux-loadtest.sh keys revoke` |

> **Produção.** Toda execução exige `--confirm-prod`, pede a palavra `PRODUCAO` no terminal e é
> vigiada por limites de segurança que param a carga de forma suave. Os IPs do STFC citados são os
> reais; o IP `203.0.113.50` e os DIDs `5500000...` são exemplos ou faixas fictícias.
