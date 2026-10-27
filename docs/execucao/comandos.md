# Comandos e opções

Formato geral:

```
./flux-loadtest.sh <ação> [opções] [-c ARQUIVO_DE_CONFIGURAÇÃO]
```

## Códigos de saída

| Código | Significado |
|---|---|
| `0` | Sucesso |
| `2` | Uso incorreto (opção inválida, valor fora do formato) |
| `3` | Configuração inválida ou arquivo ausente |
| `4` | Dependência ausente na VM de teste |
| `5` | Falha remota (SSH, smoke com falha, chave não instalada, dashboard não criado) |
| `6` | Execução interrompida (guard, Ctrl+C, "Parar teste" ou cancelamento) |

## Ações

| Ação | Função | Detalhes |
|---|---|---|
| `keys` | Chaves SSH: `create`, `trust`, `deploy`, `test`, `revoke`, `setup` | [Chaves SSH](../configuracao/chaves-ssh.md) |
| `check` | Validação somente leitura | [Fluxo](fluxo.md#1-check-validacao-somente-leitura) |
| `smoke` | Uma chamada de validação | [Fluxo](fluxo.md#2-smoke-uma-chamada) |
| `run` | Teste completo | abaixo |
| `report <dir>` | Regenera o `report.txt` a partir dos dados brutos, sem configuração nem SSH | [Arquivos](../resultados/arquivos.md) |
| `zabbix` | `setup`, `send`, `check` | [Zabbix](../configuracao/zabbix.md) |
| `capacidade` | Foto de limites e uso, sem carga | abaixo |

## `run`

| Opção | Padrão | Descrição |
|---|---|---|
| `-t, --tests` | `sip,web` | Qualquer combinação de `sip`, `web`, `mysql` |
| `-r, --cps` | — | CPS alvo (obrigatório com `sip`) |
| `--cps-start` | 10% do alvo | CPS inicial da rampa |
| `--ramp-step` | igual ao inicial | Incremento por degrau da rampa |
| `--ramp-interval` | `10` | Segundos entre incrementos |
| `-w, --window` | `300` | Janela de envio de chamadas (s) |
| `-n, --calls` | `0` | Total de chamadas; `0` = só a janela limita |
| `-H, --hold` | `30` | Duração da chamada atendida antes do BYE (s) |
| `-l, --max-concurrent` | cps x (hold + 4) x 1,2 | Limite de simultâneas no SIPp |
| `-M, --media` | `rtp` | `rtp` ou `none` |
| `--did` | — | Todas as chamadas para um único DID |
| `--web-duration` | `30` | Duração de cada alvo web (s) |
| `--web-conns` / `--web-threads` | `50` / `4` | Conexões e threads do `wrk` |
| `--mysql-duration` | `60` | Duração do sysbench (s) |
| `--baseline` / `--cooldown` | config | Sobrescrevem `BASELINE_SECONDS` / `COOLDOWN_SECONDS` |
| `--label` | — | Rótulo no nome do diretório de resultado |
| `--fs-password` | — | Pede a senha do `fs_cli` no terminal |
| `--dry-run` | — | Mostra o plano e a linha do SIPp, sem executar nada |
| `--confirm-prod` | — | **Obrigatório** para executar |
| `-y, --yes` | — | Não pede a palavra `PRODUCAO` no terminal |

!!! note "Rampa"
    Com a rampa padrão (10% do alvo, +10% a cada 10 s), o CPS alvo só é atingido depois de 90 a 120 s (a 25 CPS, ~115 s na campanha).
    A janela `-w` precisa cobrir a rampa **e** pelo menos 2 minutos no alvo; senão o degrau não
    mede o CPS pedido. Na campanha, degraus de 60 e 90 s a 25 CPS não reproduziram o atraso que
    apareceu com 240 s.

## `capacidade`

```bash
./flux-loadtest.sh capacidade --hold 500 --label antes-c5000
```

| Opção | Descrição |
|---|---|
| `-H, --hold S` | Hold planejado: alerta timeout de mídia menor ou igual a ele |
| `--label TEXTO` | Rótulo do diretório (`<data>-capacidade-<rótulo>`) |
| `--fs-password` | Pede a senha do `fs_cli` no terminal |

O `run` tira a mesma foto três vezes (`antes`, `pico`, `depois`). Leitura em
[Arquivos e relatório](../resultados/arquivos.md#capacidade).

## Exemplos

Todos os testes juntos (o MySQL exige a VM na rede interna):

```bash
./flux-loadtest.sh run --confirm-prod --fs-password -t sip,web,mysql -r 20 -H 20 -w 300 --label todos
```

Mesmo teste com todas as opções explícitas:

```bash
./flux-loadtest.sh run -c /opt/flux-loadtest/loadtest.conf --confirm-prod --fs-password -t sip,web,mysql -r 50 --cps-start 5 --ramp-step 5 --ramp-interval 10 -H 20 -w 600 -n 0 -l 1440 -M none --web-duration 60 --web-conns 50 --web-threads 4 --mysql-duration 120 --baseline 60 --cooldown 60 --label todos-cps50
```

Duração aproximada: baseline 60 s + SIP 600 s + drenagem ~25 s + 15 s + MySQL ~150 s + 15 s +
web 2 x 70 s + cooldown 60 s = **~18 minutos**.

Rampa personalizada e total fixo (de 20 a 200 CPS, +20 a cada 30 s, até 50 mil chamadas):

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 200 --cps-start 20 --ramp-step 20 --ramp-interval 30 -H 15 -w 900 -n 50000 --label rampa-200
```

Sem rampa:

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 30 --cps-start 30 -H 20 -w 300 --label sem-rampa
```

Custo de mídia (mesma carga, com e sem RTP):

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 50 -H 20 -w 300 -M none --label cps50-sem-rtp
```

```bash
./flux-loadtest.sh run --confirm-prod -t sip -r 50 -H 20 -w 300 -M rtp --label cps50-rtp
```

Só web, e web + MySQL:

```bash
./flux-loadtest.sh run --confirm-prod -t web --web-conns 50 --web-duration 60 --label web-c50
```

```bash
./flux-loadtest.sh run --confirm-prod -t web,mysql --web-conns 100 --mysql-duration 120 --label web-mysql
```

Sem interação (com `FS_CLI_PASSWORD_FILE` e `-y`):

```bash
./flux-loadtest.sh run --confirm-prod -y -t sip -r 20 -H 20 -w 300 --label noturno
```

## Referência rápida

| Objetivo | Comando |
|---|---|
| Preparar as chaves SSH | `./flux-loadtest.sh keys setup --via admin --write-config` |
| Validar o ambiente | `./flux-loadtest.sh check --fs-password` |
| Uma chamada de teste | `./flux-loadtest.sh smoke --media none` |
| Ver o plano sem executar | `./flux-loadtest.sh run --dry-run -t sip,web,mysql -r 20 -H 20 -w 300` |
| Piloto SIP | `./flux-loadtest.sh run --confirm-prod --fs-password -t sip -r 1 -H 10 -w 60 --media none --label piloto` |
| Foto de capacidade | `./flux-loadtest.sh capacidade --hold 300 --label antes` |
| Regenerar relatório | `./flux-loadtest.sh report <diretorio-da-execucao>` |
| Importar no Zabbix | `./flux-loadtest.sh zabbix send <diretorio-da-execucao>` |
| Remover as chaves | `./flux-loadtest.sh keys revoke` |
