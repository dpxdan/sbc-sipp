# Runbook do STFC

Resumo do teste completo pelo OpenSIPS no STFC. O runbook detalhado, com todos os comandos, é o
[`deploy/stfc-completo/README.md`](https://github.com/dpxdan/sbc-sipp/blob/master/deploy/stfc-completo/README.md).

```
.165  SIPp originador :5060 --INVITE--> .163 OpenSIPS :5060 (address grupo 10)
                                          --load_balancer--> FS .163:5070 | FS .162:5070
.165  SIPp atendedor  :5090 <--bridge DIRECT-IP-- FS (RTP do FS <-> .165 :20000+ e :40000+)
.165  coletor local + SSH (somente leitura) --> .163, .162, .161, .164
```

## O que muda em produção

| Alteração | Onde | Risco | Reversão |
|---|---|---|---|
| Usuário `loadtest` + sudoers do `fs_cli`/`opensips-cli` | .163, .162 | Baixo (só leitura de status) | `userdel -r loadtest` e remover o sudoers |
| `flux_monitor` + `/etc/mysql/flux-loadtest.cnf` | .161, .164 | Baixo | `DROP USER` e remover o cnf |
| .165 no grupo 10 da `address` + `address_reload` | Banco + .163 | **O .165 vira origem confiável** e pode chamar qualquer DID | `90-opensips-address-remove.sql` + `address_reload` |
| Conta de teste e DIDs `5500000xxxxxx` | Banco | CDR por chamada na conta de teste | `dids-limpar.sh remover` |
| `fsctl sps` / `fsctl max_sessions` | .163, .162 | **FS com clientes:** se o servidor saturar, chamadas reais degradam | `fs-limites.sh restaurar` |
| Firewall, fail2ban e Event Guard para o .165 | .165, .163, .162 | Baixo | Remover as regras anotadas |
| Integração com o Zabbix | Zabbix, .165 | Baixo; o menu dispara carga real | [Encerramento](encerramento.md#zabbix) |
| Carga SIP | todos | **Tráfego real no mesmo OpenSIPS, FS e banco** | Guard, degraus, Ctrl+C |

!!! warning "Janela"
    Faça o teste em horário de menor tráfego, com o responsável pelo ambiente e o NOC acompanhando.

## Ordem de execução

| # | Onde | Passo | Página |
|---|---|---|---|
| 1 | .165, .163, .162, .161 | Preflights e `00-verificacao.sql` (somente leitura) | abaixo |
| 2 | .165 | Instalação, configuração e firewall do gerador | [VM de teste](../instalacao/vm-teste.md) |
| 3 | .163, .162 | Usuário de coleta; fail2ban, Event Guard e firewall | [Servidores](../instalacao/servidores.md) |
| 4 | .161, .164 | Coleta do MySQL | [Servidores](../instalacao/servidores.md#mysql) |
| 5 | Interface + .161 | Conta, DID modelo, massa e lista | [Conta e DIDs](../instalacao/massa-dids.md) |
| 6 | .161 + .163 | Liberação do .165 no OpenSIPS | [Servidores](../instalacao/servidores.md#origem-sip-autorizada) |
| 7 | .165 | Chaves, `check`, smoke e conferência do CDR | [Fluxo](fluxo.md) |
| 8 | .165 + FS | Degraus, com `fs-limites.sh aplicar` antes de cada um | [Degraus e perfis](degraus-e-perfis.md) |
| 9 | todos | Reversão | [Encerramento](encerramento.md) |

## Preflights (somente leitura)

No .165:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/preflight-165.sh
```

Em cada SBC:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/preflight-sbc.sh 200.159.177.165
```

Anote, de cada FS, os limites atuais e o pico de sessões e de sessões por segundo do **tráfego
real** (linhas `session(s)`). Eles definem a margem dos degraus: a margem precisa ser de pelo menos
2 vezes o pico real. No .163, o preflight também mostra a `address` carregada, o `lb_list` e a
memória do OpenSIPS.

## Degraus da issue

Comando base: `./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip`.

| # | Degrau | Opções | `fs-limites.sh aplicar` |
|---|---|---|---|
| 0 | piloto | `-r 10 -H 10 -w 60 -M none --label stfc-piloto` | — |
| 1 | 1000 simultâneas | `-r 100 -H 10 -w 300 -M none --label stfc-c1000-cps100` | `150 1500` |
| 2 | 2000 simultâneas | `-r 100 -H 20 -w 300 -M none --label stfc-c2000-cps100` | `150 2500` |
| 3 | 3000 simultâneas | `-r 100 -H 30 -w 300 -M none --label stfc-c3000-cps100` | `150 3500` |
| 4 | 200 CPS | `-r 200 -H 15 -w 300 -M none --label stfc-c3000-cps200` | `250 3500` |
| 5 | 300 CPS | `-r 300 -H 10 -w 300 -M none --label stfc-c3000-cps300` | `350 3500` |
| 6 | mídia | O maior degrau sem limite atingido, com `-M rtp` e o rótulo terminado em `-rtp` | o mesmo do degrau |

Cada degrau leva de 10 a 12 minutos. Leia o `report.txt` antes do degrau seguinte e aplique os
critérios de [subir ou não o próximo degrau](../resultados/como-interpretar.md#9-subir-ou-nao-o-proximo-degrau).

Na campanha de 21/10/2026, os degraus 3 a 5 não foram executados: o sistema não sustentou 100 CPS
(veja o [estudo de caso](../resultados/estudo-de-caso-2026-10-21.md)). Para as campanhas seguintes,
os perfis `stfc-*` separam simultâneas de CPS.

## Guard do STFC

O `loadtest.conf` do STFC é mais conservador que o padrão:

| Limite | STFC | Padrão |
|---|---|---|
| CPU dos servidores | 75% | 85% |
| CPU do gerador | 70% | 90% |
| Memória | 85% | 90% |
| Falha SIP | 2% | 5% |
| Tamanho mínimo do cluster | 2 | desligado |
| Baseline / cooldown | 120 s / 120 s | 60 s / 60 s |
