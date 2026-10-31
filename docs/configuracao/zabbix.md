# Zabbix

A integração é opcional. Nada muda nos servidores testados: o Zabbix recebe, por trapper, o que a
VM de teste já coleta.

```
VM de teste                                         Zabbix (server ou proxy)
  run -> RUN_DIR (metrics/, sip/, phases, guard)      trapper :10051
           \-- lib/flux_zabbix.py send --follow ------> hosts <prefixo><id>
  zabbix send RUN_DIR (importação) -------------------/     itens dependentes (JSONPath)
```

| Modo | Como funciona |
|---|---|
| Ao vivo | Com `ZABBIX_SERVER` e `ZABBIX_LIVE=1`, o `run` inicia o envio depois dos coletores e lê os arquivos a cada 2 s. Se o Zabbix cair, os valores ficam na fila e o teste continua (`zabbix.log`) |
| Importação | `zabbix send <dir>` reenvia uma execução com os timestamps originais |
| Disparo | Perfis pré-definidos iniciados e parados pelo menu do host `<prefixo>gen` |

## Pré-requisitos

| Item | Detalhe |
|---|---|
| Zabbix | 7.2 (os templates são gerados para o 7.2; o mesmo YAML entra num 7.4) |
| Usuário da API | Escrita em hosts e templates **e permissão para criar dashboards**. Token em *Users > API tokens* |
| Trapper | A VM alcança o server (ou um proxy) em `10051/tcp`. Sem criptografia: só em rede interna |
| Agent (disparo) | O server (ou proxy) alcança a VM em `10050/tcp` |

## 1. Token e configuração

Token da API num arquivo 0600 (o `read` não mostra o token na tela):

```bash
install -m 0600 /dev/null /etc/flux-loadtest/zabbix_api.token && read -rs -p 'Token da API do Zabbix: ' T && printf '%s\n' "$T" > /etc/flux-loadtest/zabbix_api.token && unset T && echo && wc -c /etc/flux-loadtest/zabbix_api.token
```

O arquivo deve ter 65 bytes (64 hexadecimais mais a quebra de linha).

No `loadtest.conf`:

```
ZABBIX_SERVER=IP_DO_ZABBIX
ZABBIX_PORT=10051
ZABBIX_HOST_PREFIX=flt-
ZABBIX_LIVE=1
ZABBIX_API_URL=https://ENDERECO_DO_ZABBIX/api_jsonrpc.php
ZABBIX_API_TOKEN_FILE=/etc/flux-loadtest/zabbix_api.token
ZABBIX_TLS_INSECURE=0
```

## 2. Hosts, templates e dashboard

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix setup --import-template -c /etc/flux-loadtest/loadtest.conf
```

```bash
./flux-loadtest.sh zabbix check -c /etc/flux-loadtest/loadtest.conf
```

Esperado: `dashboard criado: Flux Loadtest - Resultados (flt-)` no `setup` e
`trapper ...: ok (processados 1, recusados 0)` no `check`. Com `AVISO: dashboard nao criado`
(código 5), os hosts estão prontos e falta permissão de dashboard ao usuário do token.

| Host | Templates | Origem dos dados |
|---|---|---|
| `<prefixo>opensips` | Sistema + OpenSIPS | `metrics/opensips.csv` |
| `<prefixo>fs1`, `fs2` | Sistema + FreeSWITCH | `metrics/fsN.csv` |
| `<prefixo>db1`, `db2` | Sistema + MySQL PXC | `metrics/dbN.csv` |
| `<prefixo>web` | Sistema + Web | `metrics/web.csv` |
| `<prefixo>gen` | Sistema + Gerador (+ Disparo) | `metrics/gen.csv` |
| `<prefixo>run` | Execução | `run.env`, fases, `sip/stats.csv`, `uas/stats.csv`, `web/`, `mysql/`, `guard.log`, `abort.txt` |

Depois de mudar o `lib/collector.sh`, atualize as listas em `zabbix/gen_templates.py`, gere de novo e
reimporte:

```bash
python3 zabbix/gen_templates.py > zabbix/flux-loadtest-templates.yaml
```

## 3. Importar execuções antigas

Cada execução é enviada uma vez; a marca `zabbix.sent` evita duplicar:

```bash
cd /opt/flux-loadtest && for d in /var/lib/flux-loadtest/results/20261021-*-stfc-*/; do echo "== ${d}"; ./flux-loadtest.sh zabbix send "${d%/}" -c /etc/flux-loadtest/loadtest.conf; done
```

Cada linha deve terminar em `recusados 0`. `--force` reenvia, mas só use se os valores não
chegaram: o Zabbix duplicaria os dados.

## 4. Sem alertas para o suporte

Se as ações de notificação do Zabbix não têm condição, os gatilhos do teste chegariam ao suporte.
Duas saídas:

| Opção | Como |
|---|---|
| Manutenção com coleta de dados (usada no STFC) | *Data collection > Maintenance*: grupo `Flux Loadtest`, tipo com coleta. Os problemas dos `flt-*` ficam suprimidos; o dashboard funciona |
| Definitiva | Nas ações de notificação, a condição "tag `scope` diferente de `loadtest`" (todos os gatilhos do flux-loadtest têm essa tag) |

## 5. Disparo de perfis pelo menu do Zabbix

```
Zabbix (menu Flux Loadtest do host <prefixo>gen)
  -> script global, executado pelo zabbix-agentd do servidor de testes (system.run)
     -> sudo -n /usr/local/sbin/flux-loadtest-zbx start <perfil>
        -> systemd-run (unidade flux-loadtest-zbx) -> flux-loadtest.sh run --confirm-prod -y ...
```

| Peça | Onde | Função |
|---|---|---|
| Perfis | `/etc/flux-loadtest/profiles.d/<perfil>.conf` | Parâmetros do `run` (`TESTS`, `CPS`, `WINDOW`, `HOLD`, `MEDIA`...), lidos como dado; `ZABBIX_ENABLED=1` publica o perfil |
| Tetos | `/etc/flux-loadtest/zabbix-runner.conf` (exemplo em `profiles/zabbix-runner.conf.example`; STFC em `deploy/stfc-completo/zabbix-runner.conf`) | `ZBX_MAX_CPS` (padrão 50; STFC 300) e `ZBX_MAX_WINDOW` (padrão 3600 s) |
| Wrapper | `/usr/local/sbin/flux-loadtest-zbx` | Valida o perfil, aplica os tetos, dispara a unidade systemd e grava o estado |
| Include do agent | diretório do `Include=` do `zabbix_agentd.conf` | `AllowKey` exato por perfil (e por CPS, nos perfis com `CPS_CHOICES`) e `DenyKey=system.run[*]` |
| Scripts globais | menu **Flux Loadtest** | Iniciar perfil, Plano (dry-run), Parar teste, Estado; `Iniciar <perfil> (CPS)` e `Plano <perfil> (CPS)` para cada perfil com `CPS_CHOICES` |

Preparação (servidor de testes, como root). O `zabbix-runner.conf` vem antes do `prepare`: um perfil
acima do teto fica fora do include do agent. No STFC, use `deploy/stfc-completo/zabbix-runner.conf`:

```bash
install -d -m 0755 /etc/flux-loadtest/profiles.d && install -m 0644 /opt/flux-loadtest/deploy/stfc-completo/profiles/stfc-*.conf /etc/flux-loadtest/profiles.d/
```

```bash
install -m 0644 /opt/flux-loadtest/profiles/zabbix-runner.conf.example /etc/flux-loadtest/zabbix-runner.conf
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --zabbix-server IP_DO_ZABBIX --dry-run
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --zabbix-server IP_DO_ZABBIX && /opt/flux-loadtest/install/flux-host.sh check zabbix-agent
```

Se o servidor já tem um `zabbix-agent`, o `zabbix_agentd.conf` não é alterado e o
`--zabbix-server` é ignorado: só entra o include. Repita o `prepare` depois de cada mudança nos
perfis (o `AllowKey` é por perfil; sem isso o Zabbix descobre o perfil mas o agent recusa).

No `loadtest.conf`, `ZABBIX_GEN_AGENT` (e, se quiser, `ZABBIX_SCRIPT_USRGRP`). Depois:

```bash
./flux-loadtest.sh zabbix setup --import-template --scripts -c /etc/flux-loadtest/loadtest.conf
```

Uso: *Monitoring > Hosts*, menu do host `flt-gen` > **Flux Loadtest** > Iniciar perfil.

### Perfil com CPS escolhido

Um perfil com `CPS_CHOICES` (no STFC, `stfc-cps-livre`) não aparece em **Iniciar perfil**. Ele ganha dois
scripts próprios, porque o Zabbix aceita uma única entrada por script:

| Script | Entrada | Efeito |
|---|---|---|
| `Plano stfc-cps-livre (CPS)` | Lista de CPS | Plano do `run` e o `fs-limites.sh aplicar` daquele valor, sem executar nada |
| `Iniciar stfc-cps-livre (CPS)` | Lista de CPS | Pede confirmação com o valor e inicia o teste |

O valor define a rampa (de CPS/2 a CPS, passo CPS/10) e o rótulo do resultado
(`zbx-stfc-cps-livre-100`). O script **Estado** mostra o CPS da execução em andamento e o da última de
cada perfil. Acima de 50 CPS, o wrapper exige `GUARD_MAX_PDD_MS` e `GUARD_MAX_OS_SHM_PCT` no
`loadtest.conf` ([pré-requisitos](../execucao/degraus-e-perfis.md#2-acima-de-50-cps)).

Depois de mudar `CPS_CHOICES`, repita o `flux-host.sh prepare zabbix-agent` (os `AllowKey`) e o
`zabbix setup --scripts` (a lista do menu).

Diagnóstico:

```bash
journalctl -u flux-loadtest-zbx -n 50 --no-pager
```

!!! warning "Quem executa o script dispara carga real"
    Cada perfil roda com `--confirm-prod -y`. Restrinja os scripts a um grupo
    (`ZABBIX_SCRIPT_USRGRP`) e revise os perfis como revisaria o comando. Com `TESTS` contendo
    `sip`, o perfil exige `FS_CLI_PASSWORD_FILE` (sem terminal, não há `--fs-password`).

Segurança do disparo:

- o include libera **só os comandos exatos** de cada perfil habilitado, um por valor de `CPS_CHOICES`,
  sem curinga (o `system.run` passa pelo shell); `system.run[id]`, `...start piloto; id` e um CPS fora
  da lista são recusados;
- o wrapper revalida o nome do perfil (`[a-z0-9-]`), as chaves, os valores e o CPS escolhido, e recusa
  CPS e janela acima dos tetos;
- uma execução por vez (trava + unidade systemd única);
- "Parar teste" manda SIGINT só ao processo principal: parada suave, cooldown e relatório
  (código 6).

Como ler o dashboard: [Dashboard do Zabbix](../resultados/zabbix-dashboard.md).

## 6. CPS do FreeSWITCH

Template `FluxSBC - CPS FreeSWITCH` (`zabbix/fluxsbc-cps-template.yaml`), para os FS reais. Diferente dos
templates `Flux Loadtest`, ele coleta por agent passivo, com ou sem teste em andamento.

| Item | Chave | Leitura |
|---|---|---|
| `FluxSBC - Inbound CPS` | `fluxsbc.calls.inbound` | Chamadas novas por segundo; a soma dos nós é comparável ao alvo do SIPp |
| `FluxSBC - Outbound CPS` | `fluxsbc.calls.outbound` | Pernas de saída por segundo. Abaixo do Inbound: chamadas recusadas antes do bridge. Acima: failover |
| `FluxSBC - SPS` | `fluxsbc.sps` | Entrada + saída, por nó. Compare com `sessions-per-second` do FS |

| Dashboard | Onde | Conteúdo |
|---|---|---|
| `FluxSBC - CPS FreeSWITCH` | *Dashboards* (global) | Os dois FS juntos: Inbound por nó, total empilhado, entrada x saída, SPS |
| `CPS do FreeSWITCH` | *Monitoring > Hosts*, link *Dashboards* do host | Um FS por vez (limite do dashboard de template) |

!!! warning "Sem gatilhos"
    O template não traz gatilhos. As ações de notificação de produção não têm condição, e estes hosts
    ficam fora da manutenção dos `flt-*`: um gatilho aqui chegaria ao suporte.

### Instalação

Em cada FS, como root. A troca do worker reinicia só o worker, e o restart do `zabbix-agent` deixa o host
alguns segundos sem coleta; nenhum dos dois afeta chamadas.

Senha do event socket (o `read` não mostra a senha na tela):

```bash
install -d -m 0700 /etc/fluxsbc && install -m 0600 /dev/null /etc/fluxsbc/event_socket.pass && read -rs -p 'Senha do event socket: ' S && printf '%s\n' "$S" > /etc/fluxsbc/event_socket.pass && unset S && echo
```

Worker:

```bash
mkdir -p /opt/flux/misc && install -m 0644 /opt/flux-loadtest/deploy/stfc-completo/fluxsbc-cps/worker_cps.php /opt/flux/misc/worker_cps.php && php -l /opt/flux/misc/worker_cps.php
```

```bash
install -m 0644 /opt/flux-loadtest/deploy/stfc-completo/fluxsbc-cps/fluxsbc-cps.service /etc/systemd/system/fluxsbc-cps.service && systemctl daemon-reload && systemctl enable fluxsbc-cps && systemctl restart fluxsbc-cps && systemctl status fluxsbc-cps --no-pager
```

Se existir o script antigo em `/opt/fluxsbc/`, apague-o depois de confirmar o serviço novo, porque ele tem a
senha do event socket no código. O `rmdir` só remove o diretório se estiver vazio:

```bash
rm /opt/fluxsbc/worker_cps.php && rmdir /opt/fluxsbc
```

UserParameter. O agent não sobe com a mesma chave definida duas vezes, então confira antes e não repita
`fluxsbc.calls.inbound`:

```bash
grep -rn 'fluxsbc.calls' /etc/zabbix/
```

Inclua a linha de `deploy/stfc-completo/fluxsbc-cps/userparameter_fluxsbc_cps.conf` no arquivo que aparecer
acima e reinicie o agent:

```bash
systemctl restart zabbix-agent && zabbix_agentd -t fluxsbc.calls.outbound
```

No servidor de testes, preencha `ZABBIX_CPS_HOSTS` com os nomes dos dois FS e confira, sem alterar nada:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix cps-setup --dry-run -c /etc/flux-loadtest/loadtest.conf
```

O comando mostra a situação das chaves em cada host e para se uma delas vier de outro template. Depois:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix cps-setup -c /etc/flux-loadtest/loadtest.conf
```

O token precisa de escrita nos dois FS, de permissão para dashboards e de permissão para criar o grupo
`Templates/FluxSBC`. Um item `fluxsbc.calls.inbound` criado direto no host passa a herdar do template e deve
manter o histórico: confira num FS depois do comando.

Com `ZABBIX_CPS_HOSTS` preenchida, o `zabbix setup` também mantém o gráfico `FreeSWITCH: chamadas por
segundo` na página Servidores do dashboard de resultados.

!!! note "Mudança de escala"
    A versão anterior do worker contava 2 por chamada: casava também com `Presence-Call-Direction`. O Inbound
    CPS cai pela metade a partir da troca, e o histórico anterior continua em dobro.

### Como conferir

Em bridge normal, somando os nós: Inbound = CPS do SIPp, Outbound = Inbound e SPS = 2 x Inbound.

Ao trocar a senha do event socket, atualize `/etc/fluxsbc/event_socket.pass` e reinicie o worker. Com a senha
errada, ele registra a recusa no `journalctl -u fluxsbc-cps` e os contadores param.
