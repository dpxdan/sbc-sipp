# Fluxo de um teste

Siga a ordem abaixo: cada passo valida o anterior. Todos os comandos rodam na VM de teste, a
partir de `/opt/flux-loadtest`, com `-c /etc/flux-loadtest/loadtest.conf` quando a configuração não
estiver ao lado do script.

## 1. `check`: validação somente leitura

```bash
./flux-loadtest.sh check --fs-password
```

O que é verificado:

- na VM: dependências (`sipp`, `wrk`, `ssh`, `curl`, `python3`...), versão do SIPp, `ulimit -n`,
  IP de origem SIP e quantidade de DIDs válidos;
- em todos os servidores: SSH, nome (`uname -n`) e diferença de relógio (aviso acima de 2 s);
- FreeSWITCH: `fs_cli status` (inclui `max-sessions`, `sessions-per-second` e CPU ociosa) e disco;
- OpenSIPS: `get_statistics` e `lb_list`;
- MySQL: versão, `read_only`, estado do PXC (tamanho, Primary, Synced) e em qual nó está o VIP;
- web: processos e páginas de status;
- atendedor: porta `UAS_PORT` livre;
- Zabbix, quando configurado.

Esperado no STFC: os dois FS `is ready`, `lb_list` com os dois nós, cluster com 2 nós `Synced` e a
porta 5090 livre. Se o FS não mostrar `is ready`, a senha do event socket está errada ou o usuário
não tem permissão para o `fs_cli`.

## 2. `smoke`: uma chamada

Uma única chamada de 5 s, sem SSH e sem coleta:

```bash
./flux-loadtest.sh smoke --media none
```

```bash
./flux-loadtest.sh smoke --media rtp
```

Esperado: `Concluidas com sucesso 1`, `smoke OK` e, com atendedor, `Chamadas recebidas do FS 1`.
"Encerradas pela VM (fim do hold)" é o caminho normal. No STFC, confira em seguida o CDR (débito e
custo zero, veja [Conta e DIDs](../instalacao/massa-dids.md#5-conferencia-depois-do-smoke)).

| Resultado do smoke | Causa provável |
|---|---|
| 403 | Origem fora da `address` carregada ou bloqueada pelo Event Guard |
| 401/407 | Origem fora da ACL do FS (destino direto no FS) |
| 404/480 | DID fora da massa ou não DIRECT-IP |
| 503 | `load_balancer` sem nó disponível ou limite de sessões do FS |
| "Chamadas recebidas do FS 0" com 408/502 | Firewall da VM ou saída dos FS para a VM |

## 3. `run --dry-run`: o plano

```bash
./flux-loadtest.sh run --dry-run -t sip -r 1 -H 10 -w 60 --media none
```

Mostra os servidores, as fases, a linha do SIPp, as simultâneas esperadas (CPS x hold), o limite de
simultâneas do SIPp e as estimativas. Avisa quando `--max-concurrent` fica abaixo do regime.

## 4. Piloto

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 1 -H 10 -w 60 --media none --baseline 30 --cooldown 30 --label piloto
```

Esperado: 0 falhas e chamadas encerradas por "fim do hold". Leia o relatório inteiro do piloto
antes de qualquer degrau: ele mostra se a coleta está completa (colunas `fs_*`, `os_*`, `db_*`
preenchidas) e qual é a linha de base de cada servidor.

## 5. Degraus

Um degrau por execução, lendo o relatório antes de subir. Veja
[Degraus e perfis](degraus-e-perfis.md) e os critérios de parada em
[Como interpretar](../resultados/como-interpretar.md#9-subir-ou-nao-o-proximo-degrau).

## O que acontece dentro do `run`

1. Valida opções, dependências e configuração; monta a lista de servidores e o SSH.
2. Conta os DIDs válidos e detecta o IP de origem SIP.
3. Mostra o plano. Com `--dry-run`, termina aqui.
4. Exige `--confirm-prod`, carrega a senha do `fs_cli` e pede `PRODUCAO` no terminal (`-y` pula a
   pergunta).
5. Cria `RESULTS_DIR/<data>-<label>/` e grava o console em `console.log`.
6. Testa o SSH de todos os servidores e registra a diferença de relógio.
7. Gera o CSV de chamadas, o áudio (se `rtp`) e o cenário SIPp.
8. Salva os snapshots `pre` e a foto de capacidade `antes`, e inicia os coletores em todos os
   servidores e na VM. No fim da janela de envio, a foto `pico` é tirada em segundo plano.
9. Executa as fases.
10. Para os coletores, salva os snapshots `post` e a foto `depois`, gera o `report.txt` e o
    `.tar.gz`.

| Fase | O que acontece |
|---|---|
| `baseline` | Só coleta: o ambiente sem a carga do teste (é a referência para comparar) |
| `sip` | SIPp com rampa até o CPS alvo, pela janela `-w` (ou até `-n` chamadas) |
| `sip_drain` | Sem chamadas novas; espera as ativas terminarem (até hold + 60 s) |
| `mysql_prepare` / `mysql` / `mysql_cleanup` | Cria a massa, roda o sysbench e remove as tabelas |
| `web_static` / `web_php` / `web_extra` | Um `wrk` por alvo, com 10 s de intervalo entre eles |
| `cooldown` | Só coleta: o retorno ao normal (roda mesmo depois de uma interrupção) |

Com `-t sip,web,mysql`, a ordem é:

```
baseline -> sip -> sip_drain -> mysql_prepare -> mysql -> mysql_cleanup -> web_static -> web_php -> [web_extra] -> cooldown
```

### Cenário SIP

1. Envia `INVITE sip:<DID>@<destino>` com SDP G.711 a-law (PCMA) e o header
   `X-Flux-Loadtest: <execução>`.
2. Mede INVITE -> 100 (RTD 1) e INVITE -> 200 (RTD 2).
3. Envia o ACK e, com `--media rtp`, inicia o áudio em loop.
4. Espera o BYE do FS por até `--hold`. Se ele vier antes, responde 200 e conta como "BYE remoto";
   senão envia o próprio BYE ("fim do hold").
5. Respostas de erro ao INVITE (4xx/5xx) e timeouts contam como falha.

O atendedor (`uas-answer.xml.in`) responde 180 e 200 devolvendo o `Record-Route`, recebe o ACK e
espera o BYE (até hold + 120 s).

### Parada suave

Ao fim da janela, ao estourar um limite ou com Ctrl+C, o SIPp recebe **um único** `SIGUSR1`: para
de criar chamadas e espera as ativas terminarem. Na versão 3.6.1, um segundo `SIGUSR1` trava o
SIPp, por isso o script nunca o envia duas vezes.

Durante a drenagem, o script lê as estatísticas do SIPp: sem chamadas ativas e com
sucesso + falha igual ao total criado, ele encerra o processo com `SIGTERM`. Se o SIPp parar de
gravar estatísticas, recebe `SIGTERM` depois de hold + 60 s.

Ctrl+C uma vez: parada suave, cooldown e relatório. Duas vezes: a carga é encerrada na hora.

### Teste PHP e sessões

O CodeIgniter grava sessões no MySQL (`ci_sessions`). O script obtém **um** cookie com `curl` e o
reutiliza em todas as requisições do `wrk`, com o mesmo User-Agent. Sem o cookie, o alvo é ignorado.
O arquivo do cookie é apagado no fim da fase.
