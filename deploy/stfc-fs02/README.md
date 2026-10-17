# Teste de carga no FreeSWITCH do sbc-stfc-02 (.162) a partir do .165

Runbook do primeiro teste em produção: o gerador roda no `sbc-stfc-interfaceweb` (.165) e
envia INVITE **direto** ao FreeSWITCH do `sbc-stfc-02` (.162), sem o OpenSIPS (README
principal, seção 8.4). O FS faz bridge para o atendedor (SIPp) do próprio .165, com DIDs
DIRECT-IP de uma conta de teste.

```
.165  SIPp originador :5060 --INVITE--> .162 FreeSWITCH (perfil default, 200.159.177.162:5070)
.165  SIPp atendedor  :5090 <--bridge--  (DID DIRECT-IP -> 200.159.177.165:5090, RTP 40000+)
.165  coletor local + SSH (somente leitura) --> .162, .161, .164
.165  trapper 10051 / agentd 10050 <------> Zabbix de produção
```

| Servidor | Público | Interno | Papel no teste |
|---|---|---|---|
| sbc-stfc-interfaceweb | 200.159.177.165 | 172.17.4.165 | Gerador (originador + atendedor), coletor local, agent do disparo |
| sbc-stfc-02 | 200.159.177.162 | 172.17.4.162 | Alvo: FreeSWITCH |
| banco-master-sbc-stfc | 200.159.177.161 | 172.17.4.161 | Coleta passiva (PXC) |
| banco-slave-stfc | 200.159.177.164 | 172.17.4.164 | Coleta passiva (PXC) |
| sbc-stfc-1 | 200.159.177.163 | 172.17.4.163 | Fora do teste (não recarregar a ACL dele) |

Arquivos deste diretório:

| Arquivo | Onde vai |
|---|---|
| `loadtest.conf` | .165: `/etc/flux-loadtest/loadtest.conf` |
| `profiles/fs02-*.conf` | .165: `/etc/flux-loadtest/profiles.d/` |
| `zabbix-runner.conf` | .165: `/etc/flux-loadtest/zabbix-runner.conf` |
| `preflight-165.sh`, `preflight-162.sh` | Verificação somente leitura em cada servidor |
| `sql/00-verificacao.sql` | Banco (somente leitura) |
| `sql/10-acl-lb-add.sql`, `sql/90-acl-lb-restore.sql` | Banco: libera/remove o .165 na ACL do FS |
| `sql/20-dids-create.sql`, `sql/95-dids-remove.sql` | Banco: DIDs de teste |

## Antes de começar: o que muda em produção

| Alteração | Onde | Risco | Reversão |
|---|---|---|---|
| Usuário `loadtest` + sudoers do `fs_cli` | .162 | Baixo (só leitura de status) | `userdel loadtest`, remover `/etc/sudoers.d/flux-loadtest` |
| `.165` em `acl_lb_networks` + `reloadacl` | Banco + .162 | **O nó web passa a poder enviar INVITE ao .162.** A chave é global: qualquer FS que recarregar a ACL ou reiniciar durante o teste também aceita o .165 | `90-acl-lb-restore.sql` + `reloadacl` no .162 |
| DIDs DIRECT-IP da conta de teste | Banco | CDR e billing por chamada | `95-dids-remove.sql` |
| `flux_monitor` + `/etc/mysql/flux-loadtest.cnf` | .161/.164 | Baixo (PROCESS, REPLICATION CLIENT) | `DROP USER`, remover o cnf |
| Include do agent, wrapper e sudoers do usuário `zabbix`; restart do agent | .165 | Baixo; o `zabbix_agentd.conf` existente não muda | Remover os 3 arquivos e reiniciar o agent |
| Carga SIP + RTP | .162 e .165 | **Tráfego real de clientes no mesmo FS; a interface web divide CPU com o gerador** | Guard, degraus, "Parar teste" |

Por que `acl_lb_networks`: o perfil `default` do FS usa `apply-inbound-acl=default` e
`auth-calls=true`. A lista `default` vem do `xml_curl` (`load_acl` em `fs/lib/flux.xml.php`):
`ip_map` das contas, gateways, `opensips_domain` e `acl_lb_networks`. Liberar o .165 por
`acl_lb_networks` faz a chamada seguir o mesmo caminho das que chegam pelo OpenSIPS
(operadora -> DID). Por `ip_map` na conta de teste, a chamada seria tratada como originação
de cliente: outro fluxo de dialplan, com risco de rota para operadora.

Limite do .162: no `switch.conf` do Flux, `sessions-per-second=30` e `max-sessions=1000`. Com
bridge para o atendedor, cada chamada abre **2 sessões**: teto prático de ~15 CPS e ~500
simultâneas. Os degraus vão até 10 CPS, e o disparo pelo Zabbix limita em 12 CPS.

Faça o teste em horário de menor tráfego, com o responsável pelo ambiente acompanhando.

---

## 1. .165 (gerador)

### 1.1 Instalação

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare gen --dry-run
```

O papel `gen` instala `sip-tester`, `wrk`, `sysbench` e utilitários, e grava sysctl/limits do
gerador (`/etc/sysctl.d/90-flux-loadtest.conf`, `/etc/security/limits.d/90-flux-loadtest.conf`:
buffers UDP e arquivos abertos). Revise o plano e aplique:

```bash
/opt/flux-loadtest/install/flux-host.sh prepare gen
```

### 1.2 Configuração

```bash
install -d -m 0750 /etc/flux-loadtest /etc/flux-loadtest/profiles.d /var/lib/flux-loadtest/results
```

```bash
install -m 0640 /opt/flux-loadtest/deploy/stfc-fs02/loadtest.conf /etc/flux-loadtest/loadtest.conf
```

```bash
install -m 0644 /opt/flux-loadtest/deploy/stfc-fs02/profiles/fs02-*.conf /etc/flux-loadtest/profiles.d/
```

```bash
install -m 0644 /opt/flux-loadtest/deploy/stfc-fs02/zabbix-runner.conf /etc/flux-loadtest/zabbix-runner.conf
```

Preencha em `/etc/flux-loadtest/loadtest.conf`: `ZABBIX_SERVER`, `ZABBIX_API_URL` e
`ZABBIX_SCRIPT_USRGRP` (parte 2). Senha do event socket do .162 (vai pelo stdin do SSH, não
pela linha de comando):

```bash
install -m 0600 /dev/null /etc/flux-loadtest/fs_cli.pass
```

```bash
read -r -s -p "Senha do event socket do .162: " p && printf '%s\n' "$p" > /etc/flux-loadtest/fs_cli.pass && unset p
```

### 1.3 Preflight (somente leitura)

```bash
bash /opt/flux-loadtest/deploy/stfc-fs02/preflight-165.sh
```

Confere: origem da rota até o .162 (= `SIP_LOCAL_IP`), portas 5060 e 5090 livres, ferramentas,
SSH até .162/.161/.164, trapper do Zabbix, firewall de entrada e o agentd existente.

Firewall do .165: com política `drop`, libere **vindo de 200.159.177.162**: `5060/udp`
(respostas ao originador), `5090/udp` (atendedor), `20000-20999/udp` (RTP do originador,
`RTP_PORT_BASE`) e `40000-40999/udp` (RTP do atendedor, `UAS_RTP_PORT_BASE`). São 2 portas por
chamada simultânea em cada lado: ~400 no degrau de 10 CPS.

### 1.4 Chaves SSH (coleta somente leitura)

Com um usuário administrativo com sudo no .162, .161 e .164 (pede a senha dele uma vez por
servidor; a chave entra com `from=`, sem PTY e sem encaminhamentos):

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh keys setup --via admin --write-config -c /etc/flux-loadtest/loadtest.conf
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh check -c /etc/flux-loadtest/loadtest.conf
```

O `check` só fica verde depois das partes 3 e 4 (usuário `loadtest`, sudoers, credencial do
MySQL).

### 1.5 Execução (depois das partes 2, 3 e 4)

Uma chamada, sem mídia, para validar ACL, DID, atendedor e CDR:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh smoke --media none -c /etc/flux-loadtest/loadtest.conf
```

Confira no banco a chamada com `sql/00-verificacao.sql` (bloco 5: `ANSWER`, `call_direction`
`inbound`, débito e custo **zero**). Se o débito não for zero, pare: a conta tem tarifa.

Degraus, um por vez, lendo o relatório (`/var/lib/flux-loadtest/results/<data>-<rótulo>/report.txt`)
antes do próximo. Pelo terminal (o plano, sem executar, com `--dry-run`):

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip -r 1 -H 10 -w 60 -M none --label fs02-piloto
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip -r 5 --cps-start 1 --ramp-step 1 -H 20 -w 180 --label fs02-cps5
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip -r 10 --cps-start 2 --ramp-step 2 --ramp-interval 15 -H 20 -w 300 --label fs02-cps10
```

Ou pelo Zabbix (parte 2), com os perfis `fs02-piloto`, `fs02-cps5` e `fs02-cps10`.

Não use `-t web` neste cenário: o `wrk` mediria a própria interface web onde ele roda. `-t mysql`
exige a rede interna até o VIP e fica para outro teste.

Critérios para não subir o degrau seguinte: falhas SIP acima de 1%, `503` do FS (limite de
sessões), CPU do .162 acima de 70%, CPU do .165 acima de 50%, `udp_rcvbuf_err_s` no .162,
flow control no PXC, ou reclamação de clientes. O guard interrompe sozinho nos limites do
`loadtest.conf` (CPU 85% nos servidores, 60% no gerador, falhas 5%, WSREP).

---

## 2. Zabbix

### 2.1 Requisitos no Zabbix de produção (7.2.3)

- Token de API (Users > API tokens) com permissão de escrita em hosts, templates e scripts,
  gravado no .165 em `/etc/flux-loadtest/zabbix_api.token` (0600).
- Trapper `10051/tcp` do Zabbix server alcançável a partir do .165.
- O Zabbix server (ou proxy) que monitora o .165 já está no `Server=` do agentd do .165: ele
  executa os scripts em modo passivo (`10050/tcp`).
- Um grupo de usuários para os scripts (`ZABBIX_SCRIPT_USRGRP`), com escrita no host group
  "Flux Loadtest".

```bash
install -m 0600 /dev/null /etc/flux-loadtest/zabbix_api.token
```

```bash
read -r -s -p "Token da API do Zabbix: " t && printf '%s\n' "$t" > /etc/flux-loadtest/zabbix_api.token && unset t
```

### 2.2 Agent do .165 (disparo)

O agentd do .165 já é monitorado: o `prepare` **não altera** o `zabbix_agentd.conf` (não passe
`--zabbix-server`). Ele grava só `/usr/local/sbin/flux-loadtest-zbx`,
`/etc/sudoers.d/flux-loadtest-zbx` e `/etc/zabbix/zabbix_agentd.d/flux-loadtest.conf`
(`AllowKey` exato por perfil + `DenyKey=system.run[*]`) e reinicia o agent.

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent --dry-run
```

Atenção aos avisos do plano: `AllowKey=system.run[*]` ou `EnableRemoteCommands=1` já existentes
anulam a restrição por perfil; sem `Include` de `zabbix_agentd.d`, o include não é lido.

```bash
/opt/flux-loadtest/install/flux-host.sh prepare zabbix-agent
```

```bash
/opt/flux-loadtest/install/flux-host.sh check zabbix-agent
```

### 2.3 Template, hosts e scripts

Template: `zabbix/flux-loadtest-templates.yaml` (Sistema, FreeSWITCH, MySQL PXC, Gerador,
Execução e Disparo). O `setup` importa, cria os hosts e os scripts:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix setup --import-template --scripts -c /etc/flux-loadtest/loadtest.conf
```

| Host | Servidor | Dados |
|---|---|---|
| `flt-fs1` | .162 (o primeiro e único de `FS_HOSTS`) | Sistema + FreeSWITCH, por trapper durante o teste |
| `flt-db1`, `flt-db2` | .161, .164 | Sistema + MySQL PXC |
| `flt-gen` | .165 | Sistema + Gerador (trapper) e Disparo (agent 10050) |
| `flt-run` | — | Execução: parâmetros, fase, SIPp, atendedor, guard, resultado |

Os hosts `flt-*` são separados dos hosts de monitoramento normal dos servidores: só recebem
dados durante os testes.

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh zabbix check -c /etc/flux-loadtest/loadtest.conf
```

Uso: Monitoramento > Hosts > `flt-gen` > menu **Flux Loadtest** > "Plano (dry-run)" e depois
"Iniciar perfil" (lista com os perfis `fs02-*`, com confirmação). "Parar teste" faz parada suave
(cooldown e relatório; código 6). Diagnóstico no .165: `journalctl -u flux-loadtest-zbx`.

---

## 3. .162 (sbc-stfc-02)

Nada no FreeSWITCH é reconfigurado ou reiniciado. As alterações são: usuário de coleta, ACL
temporária (pelo banco + `reloadacl`) e liberações de rede para o .165.

### 3.1 Preflight (somente leitura)

```bash
bash preflight-162.sh 200.159.177.165
```

(copie `deploy/stfc-fs02/preflight-162.sh` para o .162). Confere: perfil `default` em
`200.159.177.162:5070`, `sessions-per-second` e canais em uso, se o `flux.xml.php` do .162 tem
`acl_lb_networks`, a ACL atual para o .165, o sudo do `loadtest`, disco, firewall e fail2ban.

Se o `flux.xml.php` do .162 **não** tiver `acl_lb_networks` (versão anterior a 02/09/2026), pare:
a liberação da seção 3.3 não teria efeito. Reavalie com o responsável (atualizar o `fs/lib` do
.162, ou outra forma de autorização).

### 3.2 Usuário de coleta

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch --dry-run
```

Cria o usuário `loadtest` (sem senha; acesso só pela chave do 1.4) e
`/etc/sudoers.d/flux-loadtest` com `loadtest ALL=(root) NOPASSWD: /usr/bin/fs_cli` (validado com
`visudo -cf` antes de gravar).

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch
```

### 3.3 ACL temporária para o .165

No nó 1 do banco (somente leitura primeiro):

```bash
mysql flux < sql/00-verificacao.sql
```

O bloco 1 precisa mostrar a linha `acl_lb_networks`. Guarde o valor atual:

```bash
mysql -N -B -e "SELECT value FROM \`system\` WHERE name = 'acl_lb_networks'" flux > /root/acl_lb_networks.antes
```

Escrita no banco de produção (acrescenta `200.159.177.165/32`, idempotente):

```bash
mysql flux < sql/10-acl-lb-add.sql
```

**Só no .162** (não no .163):

```bash
fs_cli -x reloadacl
```

```bash
fs_cli -x 'acl 200.159.177.165 default'
```

Esperado: `true`.

### 3.4 Rede

- Firewall do .162: entrada de `200.159.177.165` em `5070/udp` e na faixa de RTP do FS
  (`rtp-start-port`-`rtp-end-port` do `switch.conf`, mostrada pelo preflight).
- Saída do .162 para `200.159.177.165`: `5060/udp`, `5090/udp`, `20000-20999/udp` e
  `40000-40999/udp`.
- fail2ban: `200.159.177.165` em `ignoreip` do jail do SIP. Event Guard do Flux: whitelist do
  `200.159.177.165` pela interface. Sem isso, o volume de INVITE pode banir o gerador no meio
  do teste.

---

## 4. Bancos (.161 e .164) e massa de teste

### 4.1 Coleta passiva

Senha do `flux_monitor`, igual nos dois nós (arquivo 0600, alfanumérica, 12+ caracteres):

```bash
install -m 0600 /dev/null /root/flux_monitor.pass
```

```bash
read -r -s -p "Senha do flux_monitor: " p && printf '%s\n' "$p" > /root/flux_monitor.pass && unset p
```

No .161 (cria o usuário; o PXC replica para o .164):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare mysql --monitor-pass-file /root/flux_monitor.pass --create-db-user
```

No .164 (só o cnf):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare mysql --monitor-pass-file /root/flux_monitor.pass
```

### 4.2 Conta e DIDs de teste

1. Pela interface: conta de teste ativa, **sem tarifa**, com crédito e `maxchannels` que não
   limitem o teste (300 ou mais). Anote o `accounts.id`.
2. Pela interface: **um** DID DIRECT-IP nessa conta, destino `200.159.177.165:5090`. Compare as
   colunas dele com o `INSERT` de `sql/20-dids-create.sql`.
3. Preencha `@conta` e `@prefixo` (faixa fictícia) em `sql/20-dids-create.sql` e rode (1.000 DIDs
   por execução):

```bash
mysql flux < sql/20-dids-create.sql
```

4. No .165, exporte a lista (somente leitura; ajuste a conta). Pelo VIP, se o .165 tiver
   cliente MySQL e usuário de leitura; senão, gere no banco e copie:

```bash
mysql -N -B -e "SELECT number FROM dids WHERE accountid = <CONTA> AND status = 0 AND call_type = 2 AND extensions = '200.159.177.165:5090'" flux > /root/dids.txt
```

No .165: `/etc/flux-loadtest/dids.txt` (0644), um DID por linha.

---

## 5. Ordem de execução

| # | Onde | Passo |
|---|---|---|
| 1 | .165, .162, banco | Preflights e `00-verificacao.sql` (somente leitura) |
| 2 | .162 | 3.2 usuário de coleta; 3.4 firewall, fail2ban, Event Guard |
| 3 | .161, .164 | 4.1 coleta; 4.2 conta e DIDs |
| 4 | .165 | 1.1 a 1.4: instalação, configuração, chaves, `check` |
| 5 | banco + .162 | 3.3 ACL temporária + `reloadacl` só no .162 |
| 6 | .165 | `smoke --media none` e conferência do CDR |
| 7 | .165 + Zabbix | 2.2 e 2.3: agent, template, hosts e scripts |
| 8 | .165 / Zabbix | Degraus: piloto -> 5 CPS -> 10 CPS, lendo o relatório entre eles |
| 9 | todos | Seção 6: reversão |

## 6. Reversão (ao fim da campanha ou ao abortar)

No banco e no .162 (primeiro a ACL, para o .165 deixar de poder enviar chamadas):

```bash
mysql flux < sql/90-acl-lb-restore.sql
```

```bash
fs_cli -x reloadacl
```

```bash
fs_cli -x 'acl 200.159.177.165 default'
```

Esperado: `false`. Se algum outro FS recarregou a ACL ou reiniciou durante o teste, rode o
`reloadacl` nele também.

DIDs de teste (repita até `removidos = 0`):

```bash
mysql flux < sql/95-dids-remove.sql
```

No .165, remover as chaves de coleta dos servidores:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh keys revoke -c /etc/flux-loadtest/loadtest.conf
```

Opcional, se o disparo pelo Zabbix não for mais usado: no .165, remover
`/etc/zabbix/zabbix_agentd.d/flux-loadtest.conf`, `/etc/sudoers.d/flux-loadtest-zbx` e
`/usr/local/sbin/flux-loadtest-zbx` e reiniciar o `zabbix-agent`. Desfazer as liberações de
firewall, fail2ban e Event Guard do .165 no .162.

Os backups de cada `prepare` ficam em `/var/backups/flux-loadtest/<data>/` no servidor onde ele
rodou.
