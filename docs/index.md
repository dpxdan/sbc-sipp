# Flux Loadtest

Ferramenta de teste de carga do FluxSBC (WEB-1437). Roda numa **VM de teste** separada e atua nos
servidores por SSH:

- gera carga SIP (INVITE para DIDs) com SIPp, com um segundo SIPp atendendo as chamadas;
- gera carga HTTP no nginx + PHP-FPM com `wrk`;
- opcionalmente, gera carga no MySQL com `sysbench`, em schema isolado;
- coleta CPU, memória, rede, disco e métricas de cada serviço em todos os servidores, durante
  todo o teste, sem instalar nem gravar nada neles;
- gera um relatório `report.txt` por execução, com os dados brutos ao lado, e opcionalmente envia
  tudo ao Zabbix.

!!! warning "Produção"
    O ambiente STFC atende clientes reais. Toda execução exige `--confirm-prod`, pede a palavra
    `PRODUCAO` no terminal e é vigiada por limites de segurança (guard) que param a carga de forma
    suave. Use `--dry-run` para revisar o plano antes.

## Por onde começar

| Você é | Leia |
|---|---|
| Quem vai instalar e rodar os testes | [Arquitetura](arquitetura.md), [Instalação](instalacao/vm-teste.md), [Configuração](configuracao/loadtest-conf.md) e [Fluxo de um teste](execucao/fluxo.md) |
| Quem vai executar uma campanha no STFC | [Runbook do STFC](execucao/runbook-stfc.md), [Degraus e perfis](execucao/degraus-e-perfis.md) e [Encerramento](execucao/encerramento.md) |
| Quem vai analisar os resultados | [Como interpretar](resultados/como-interpretar.md) e [Leitura por equipe](resultados/por-equipe.md) |
| Gestão, NOC, voz, banco, infra ou web | [Leitura por equipe](resultados/por-equipe.md), na seção da sua equipe |
| Quem acompanha pelo Zabbix | [Dashboard do Zabbix](resultados/zabbix-dashboard.md) |

## Fluxo em cinco passos

1. **Preparar:** instalar o gerador, preparar os servidores (usuário de coleta, sudoers, credencial
   do banco), criar a conta e os DIDs de teste e liberar a origem SIP.
2. **Configurar:** `loadtest.conf`, chaves SSH (`keys setup`) e, se for usar, o Zabbix.
3. **Validar:** `check` (somente leitura), `smoke` (uma chamada) e `run --dry-run` (plano).
4. **Executar:** piloto e depois um degrau por execução, lendo o relatório antes de subir.
5. **Analisar e encerrar:** interpretar o relatório, registrar o resultado e reverter as liberações.

## Componentes do repositório

| Caminho | Função |
|---|---|
| `flux-loadtest.sh` | Orquestrador: `keys`, `check`, `smoke`, `run`, `report`, `zabbix`, `capacidade` |
| `lib/collector.sh` | Coletor de métricas, enviado por SSH (`bash -s`) |
| `lib/capacidade.sh` | Foto de limites e uso de cada servidor (antes, pico, depois) |
| `lib/flux_zabbix.py` | Envio ao Zabbix (trapper) e provisionamento pela API |
| `scenarios/` | Cenários SIPp: originador (`uac-did.xml.in`) e atendedor (`uas-answer.xml.in`) |
| `profiles/` | Perfis de teste para o disparo pelo Zabbix |
| `bin/flux-loadtest-zbx` | Wrapper chamado pelo zabbix-agentd para iniciar e parar perfis |
| `zabbix/` | Templates do Zabbix 7.2 e o gerador deles |
| `install/` | `flux-host.sh`: prepara servidores existentes ou instala o laboratório |
| `lab/` | Laboratório STFC em Docker (`lab.sh`) ou em VMs (`lab/vm/vmlab.sh`) |
| `deploy/stfc-completo/` | Runbook, SQL, scripts e resultados da campanha no STFC |

## Editar esta documentação

Na raiz do repositório:

```bash
python3 -m venv .venv && . .venv/bin/activate && pip install -r docs/requirements.txt
```

```bash
mkdocs serve
```

Para gerar o site estático em `site/`:

```bash
mkdocs build --strict
```

Páginas novas ficam em `docs/` e precisam entrar em `nav` no `mkdocs.yml`.
