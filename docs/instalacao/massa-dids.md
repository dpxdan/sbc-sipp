# Conta e DIDs de teste

## Destino recomendado: DID DIRECT-IP para o atendedor

O dialplan Lua (`custom_inbound_2` do `flux.xml.lua`) faz `bridge sofia/<perfil>/<DID>@<extensions>`.
Com `extensions` = IP e porta da VM, o FS entrega a chamada ao SIPp atendedor (`UAS_PORT`), que
responde 200 OK com SDP e, com `--media rtp`, também transmite.

A chamada passa por OpenSIPS, `load_balancer`, consulta do DID no MySQL, billing e bridge com
mídia nos dois sentidos, como o tráfego real: os DIDs ativos do STFC encaminham para PBXs por IP.

Por que não a caixa postal (validado no laboratório em 14/10/2026):

- DID para ramal **não registrado** termina em 480: o `flux-sipdevice-routing.lua` desliga a
  chamada antes do `leave_voicemail`;
- DID para ramal **registrado** depende do nó: o REGISTER fica no FS escolhido pelo `dispatcher`,
  mas o `load_balancer` distribui as chamadas entre os dois FS, e no outro nó o resultado é
  `USER_NOT_REGISTERED`.

!!! danger "Não use DIDs ativos de clientes"
    Na base do STFC (outubro/2026), os 66,5 mil DIDs ativos encaminham para PBXs e números
    externos de 116 contas. Usá-los no teste geraria chamadas reais para os clientes.

## Requisitos de cada DID

- DIRECT-IP (`call_type = 2`) com `extensions = <IP da VM visto pelos FS>:<UAS_PORT>`
  (atrás de NAT, o IP público da VM);
- conta de teste **sem tarifa** (cada chamada gera CDR e passa pelo billing), com `maxchannels` e
  crédito que não limitem o teste;
- faixa de numeração fictícia, que nenhuma operadora encaminhe;
- `bypass_media = 0`, para o FS ancorar o RTP (com `1`, o teste não mede mídia nos FS);
- `leg_timeout` diferente de 0.

Use pelo menos tantos DIDs quanto chamadas simultâneas.

!!! note "Padrões do DID criado pela interface"
    Na campanha, o DID modelo criado pela interface veio com `bypass_media = 1` e
    `leg_timeout = 0`. Os dois foram ajustados (`0` e `30`) antes da clonagem. Confira esses campos
    no modelo.

## Procedimento no STFC

Os SQL ficam em `deploy/stfc-completo/sql/`. Todos os passos com escrita rodam no nó 1 do banco
(`.161`), com o responsável pelo ambiente.

### 1. Conferência (somente leitura)

```bash
cd /opt/flux-loadtest/deploy/stfc-completo/sql && mysql flux < 00-verificacao.sql
```

O bloco 5 precisa sair vazio (nenhum DID na faixa `5500000`).

### 2. Conta e DID modelo (pela interface do Flux)

1. **Conta de teste:** ativa, pós-paga, sem tarifa (rate group de custo zero), `credit_limit` alto
   e `maxchannels` = 0. Anote o `accounts.id`.
2. **DID modelo** nessa conta: número `5500000000000`, tipo DIRECT-IP, destino
   `200.159.177.165:5090`, sem `maxchannels`.

Conferência (troque `<ID>`):

```bash
{ echo "SET @conta = <ID>;"; cat 00-verificacao.sql; } | mysql flux
```

Blocos 4 e 5: conta ativa e sem limite de canais; 1 DID na faixa, `call_type` 2, destino
`200.159.177.165:5090`.

### 3. Massa de DIDs (escrita)

O `20-dids-create.sql` clona o DID modelo (todas as colunas, exceto `id` e `number`), pela chave
primária e pelo índice de `accountid`. Primeiro, um lote de validação com 10 DIDs:

```bash
{ echo "SET @conta = <ID>; SET @inicio = 1; SET @lote = 10;"; cat 20-dids-create.sql; } | mysql flux
```

Esperado: `modelo_ok = 1` e `inseridos = 10`. Depois os lotes de 10.000, um por vez (números já
criados são pulados). O tamanho do lote evita um writeset grande no PXC:

```bash
for i in 1 10001 20001 30001 40001 50001 60001 70001 80001 90001; do { echo "SET @conta = <ID>; SET @inicio = $i;"; cat 20-dids-create.sql; } | mysql flux || break; done
```

Total esperado: 100.000 (o modelo mais `5500000000001` a `5500000099999`).

### 4. Lista para o gerador

```bash
mysql -N -B -e "SELECT number FROM dids WHERE accountid = <ID> AND status = 0 AND call_type = 2 AND extensions = '200.159.177.165:5090' AND number LIKE '5500000%'" flux > /root/dids.txt
```

```bash
scp /root/dids.txt root@200.159.177.165:/etc/flux-loadtest/dids.txt
```

O `DID_FILE` aceita um DID por linha, comentários com `#` e linhas vazias. O `run` embaralha os
DIDs válidos no CSV de chamadas.

### 5. Conferência depois do smoke

Depois do primeiro `smoke`, o bloco 6 do `00-verificacao.sql` precisa mostrar `ANSWER` com débito
e custo **zero**. Se houver débito, pare: a conta tem tarifa.

## Remoção

Pelo `dids-limpar.sh`, em lotes, com confirmação. Veja
[Encerramento e reversão](../execucao/encerramento.md#3-dids-de-teste).

## Sem atendedor

Sem `UAS_PORT`, o flux-loadtest envia para qualquer DID que o FS atenda sozinho (por exemplo, caixa
postal). O relatório só não terá a seção do atendedor. Nesse caso, cada chamada grava cerca de
`(hold - saudação) x 16 KB/s` em `FS_DISK_PATH`; o plano mostra a estimativa e `VM_BOXES` conta as
mensagens nos snapshots.
