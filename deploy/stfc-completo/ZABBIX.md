# Resultados do teste de carga do STFC no Zabbix

Roteiro para exibir os resultados do flux-loadtest no Zabbix que já existe, com o gerador no
`sbc-stfc-interfaceweb` (.165):

1. hosts, templates e o dashboard **Flux Loadtest - Resultados** (`zabbix setup`);
2. importação das execuções de 21/10/2026 (`zabbix send`);
3. envio ao vivo nos próximos testes (`ZABBIX_SERVER`);
4. `zabbix-agent` no .165 para iniciar e parar perfis pelo menu do Zabbix.

Detalhes de cada peça na seção 19 do `README.md` da raiz.

## O dashboard

Criado ou atualizado pelo `zabbix setup` (idempotente), com o nome
`Flux Loadtest - Resultados (<prefixo>)`:

| Página | Widgets |
|---|---|
| Resultados | Tabela com uma linha por execução: execução, status, chamadas criadas, falhas (%), pico de simultâneas, pico de CPS, INVITE -> 200 médio, originadas que não chegaram ao atendedor, motivo da interrupção. Gráficos de CPS alvo e realizado, simultâneas (originador e atendedor), INVITE -> 100/200 e falhas/retransmissões por período. Problemas do grupo `Flux Loadtest` |
| Servidores | CPU e memória por servidor, sessões e chamadas dos FreeSWITCH, memória compartilhada, diálogos e transações do OpenSIPS, consultas e CPU do MySQL, pacotes recebidos |

Os gráficos usam padrão de host e de nome de item (`flt-*`, `flt-fs*`...): servidores novos
entram sozinhos. Para ver uma execução antiga, escolha o período dela no seletor de tempo do
dashboard (as de 21/10/2026: das 20:35 às 23:58).

Validado num Zabbix 7.2.3 com a importação das 8 execuções de 21/10/2026: a tabela trouxe os
mesmos números dos `report.txt` (ex.: `stfc-meta-c2000`, 2122 criadas, 7,3% de falha, pico de
1962 simultâneas, INVITE -> 200 de 140 ms).

## Pré-requisitos

| Item | Detalhe |
|---|---|
| Zabbix | 7.2 (o template é gerado para o 7.2; entra também num 7.4) |
| Usuário da API | Escrita em hosts e templates **e permissão para criar dashboards** (ex.: um usuário do tipo Admin). Token em *Users > API tokens* |
| Trapper | O .165 alcança o server (ou um proxy) na porta **10051/TCP**. O trapper não tem criptografia: só em rede interna |
| Agent (passo 5) | O server (ou proxy) alcança o .165 na porta **10050/TCP** |

Antes de alterar o firewall do .165 ou do Zabbix, confirme o impacto: são duas regras de
entrada/saída restritas aos IPs do Zabbix e do .165, sem efeito no tráfego SIP.

## 1. Configuração no .165

Atualize o repositório (o `zabbix setup` novo cria o dashboard):

```bash
cd /opt/flux-loadtest && git pull --ff-only && git log --oneline -1
```

Token da API num arquivo 0600 (cole o token quando o `read` pedir; ele não aparece na tela):

```bash
install -m 0600 /dev/null /etc/flux-loadtest/zabbix_api.token && read -rs -p 'Token da API do Zabbix: ' T && printf '%s\n' "$T" > /etc/flux-loadtest/zabbix_api.token && unset T && echo && wc -c /etc/flux-loadtest/zabbix_api.token
```

O arquivo deve ter 65 bytes (64 hexadecimais mais a quebra de linha).

Em `/etc/flux-loadtest/loadtest.conf`, preencha (troque `IP_DO_ZABBIX` e a URL):

```
ZABBIX_SERVER=IP_DO_ZABBIX
ZABBIX_PORT=10051
ZABBIX_HOST_PREFIX=flt-
ZABBIX_LIVE=1
ZABBIX_API_URL=https://ENDERECO_DO_ZABBIX/api_jsonrpc.php
ZABBIX_API_TOKEN_FILE=/etc/flux-loadtest/zabbix_api.token
ZABBIX_TLS_INSECURE=0
```

`ZABBIX_TLS_INSECURE=1` só se a interface usar certificado autoassinado.

## 2. Hosts, templates e dashboard

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix setup --import-template -c /etc/flux-loadtest/loadtest.conf
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix check -c /etc/flux-loadtest/loadtest.conf
```

Esperado: `dashboard criado: Flux Loadtest - Resultados (flt-)` no `setup` e
`trapper ...: ok (processados 1, recusados 0)` no `check`. Se o `setup` disser
`AVISO: dashboard nao criado`, os hosts estão prontos e falta permissão de dashboard ao usuário
do token.

## 3. Importar as execuções de 21/10/2026

Cada execução é enviada uma vez, com os horários originais (a marca `zabbix.sent` evita
duplicar):

```bash
cd /opt/flux-loadtest && for d in /var/lib/flux-loadtest/results/20261021-*-stfc-*/; do echo "== ${d}"; ./flux-loadtest.sh zabbix send "${d%/}" -c /etc/flux-loadtest/loadtest.conf; done
```

Cada linha deve terminar em `recusados 0`. Depois, no Zabbix: *Dashboards >
Flux Loadtest - Resultados (flt-)*, período de 21/10/2026 20:35 a 23:58.

O resultado de cada execução (identificador, status, totais e INVITE -> 200 médio) é montado
na importação, a partir do `run.env`, do `abort.txt` e do `sip/stats.csv` de cada diretório.

## 4. Envio ao vivo

Com `ZABBIX_SERVER` e `ZABBIX_LIVE=1`, todo `run` passa a aparecer no Zabbix enquanto roda.
Nada muda no comando. Se o Zabbix cair, o teste continua e os valores ficam na fila
(`zabbix.log` no diretório da execução).

## 5. Agent no .165: iniciar e parar perfis pelo Zabbix

**Impacto no .165 (produção):**
- instala o pacote `zabbix-agent` 7.2 do repositório oficial do Zabbix, se faltar, e abre o
  serviço na porta 10050, aceitando só o `Server=` informado;
- se o .165 já tiver o `zabbix-agent` (servidor já monitorado), o `zabbix_agentd.conf` não é
  alterado e o `--zabbix-server` é ignorado: só entra o include do flux-loadtest, no diretório
  do `Include=` do agent. No .165 (agent 6.0.14 do Debian, `Server=200.159.177.242`):
  `/etc/zabbix/zabbix_agentd.conf.d/flux-loadtest.conf`, ao lado do
  `userparameter_fluxsbc.conf`. O `DenyKey=system.run[*]` não muda nada no que existe: o 6.0
  já bloqueia `system.run` por padrão, e o host não usa `system.run` nem comando remoto;
- o restart do `zabbix-agent` deixa o .165 alguns segundos sem coleta;
- instala `/usr/local/sbin/flux-loadtest-zbx`, `/etc/sudoers.d/flux-loadtest-zbx` (o usuário
  `zabbix` roda só esse wrapper) e o include do agent, que libera apenas os comandos exatos de
  cada perfil;
- quem tiver permissão de executar os scripts no Zabbix dispara carga nos servidores reais. Use
  `ZABBIX_SCRIPT_USRGRP` para restringir a um grupo.

Perfis do STFC (deste diretório):

| Perfil | Carga |
|---|---|
| `stfc-piloto` | 10 CPS por 60 s |
| `stfc-cps20` | 20 CPS sustentados por ~3 min (o maior valor com atraso aceitável hoje) |
| `stfc-c1000` | 1000 simultâneas a 10 CPS |

O wrapper recusa CPS acima de 50 e janela acima de 3600 s
(`/etc/flux-loadtest/zabbix-runner.conf`).

```bash
install -d -m 0755 /etc/flux-loadtest/profiles.d && install -m 0644 /opt/flux-loadtest/deploy/stfc-completo/profiles/stfc-*.conf /etc/flux-loadtest/profiles.d/ && ls -l /etc/flux-loadtest/profiles.d
```

Plano, sem alterar nada (troque `IP_DO_ZABBIX`):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --zabbix-server IP_DO_ZABBIX --dry-run
```

Aplicação, depois de revisar o plano:

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --zabbix-server IP_DO_ZABBIX && /opt/flux-loadtest/install/flux-host.sh check zabbix-agent
```

No `loadtest.conf`, o IP pelo qual o Zabbix alcança o agent do .165 (e, se quiser, o grupo que
pode executar os scripts):

```
ZABBIX_GEN_AGENT=IP_DO_165_VISTO_PELO_ZABBIX
ZABBIX_SCRIPT_USRGRP=
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix setup --scripts -c /etc/flux-loadtest/loadtest.conf
```

Uso: *Monitoring > Hosts*, menu do host `flt-gen` > **Flux Loadtest** > Iniciar perfil
(com confirmação), Plano (dry-run), Parar teste (parada suave), Estado. O teste com SIP exige
`FS_CLI_PASSWORD_FILE` no `loadtest.conf`, já usado na campanha. Diagnóstico:

```bash
journalctl -u flux-loadtest-zbx -n 50 --no-pager
```

## Reversão

| Item | Como desfazer |
|---|---|
| Agent no .165 | `systemctl disable --now zabbix-agent`; `apt purge zabbix-agent`; remover `/etc/sudoers.d/flux-loadtest-zbx`, `/usr/local/sbin/flux-loadtest-zbx` e `/etc/flux-loadtest/profiles.d/` |
| Envio ao vivo | Esvaziar `ZABBIX_SERVER` no `loadtest.conf` |
| Hosts, templates, scripts e dashboard | No Zabbix: excluir o grupo de hosts `Flux Loadtest` e seus hosts, os templates do grupo `Templates/Flux Loadtest`, os scripts do menu `Flux Loadtest` e o dashboard |
| Token | Revogar em *Users > API tokens* e apagar `/etc/flux-loadtest/zabbix_api.token` |
