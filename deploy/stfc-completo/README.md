# Teste de carga completo do STFC pelo OpenSIPS, a partir do .165

Runbook dos cenários da WEB-1437 nos servidores do STFC, sem Docker: 100/200/300 CPS e
1000/2000/3000 chamadas simultâneas. O gerador roda no `sbc-stfc-interfaceweb` (.165) e entra
como operadora no OpenSIPS. O caminho é o das chamadas reais:

```
.165  SIPp originador :5060 --INVITE--> .163 OpenSIPS :5060 (address grupo 10)
                                          --load_balancer--> FS .163:5070 | FS .162:5070
                                                              (dialplan Lua, DID no MySQL pelo VIP)
.165  SIPp atendedor  :5090 <--bridge DIRECT-IP-- FS (RTP do FS <-> .165 :20000+ e :40000+)
.165  coletor local + SSH (somente leitura) --> .163, .162, .161, .164
```

| Servidor | Público | Interno | Papel no teste |
|---|---|---|---|
| sbc-stfc-interfaceweb | 200.159.177.165 | 172.17.4.165 | Gerador (originador + atendedor) e coletor local |
| sbc-stfc-1 | 200.159.177.163 | 172.17.4.163 | Alvo: OpenSIPS + FreeSWITCH |
| sbc-stfc-02 | 200.159.177.162 | 172.17.4.162 | Alvo: FreeSWITCH |
| banco-master-sbc-stfc | 200.159.177.161 | 172.17.4.161 | Coleta passiva (PXC) e escrita da massa de teste |
| banco-slave-stfc | 200.159.177.164 | 172.17.4.164 | Coleta passiva (PXC) |

Diferença em relação ao `deploy/stfc-fs02/` (primeiro teste, direto no FS do .162): aqui
o .165 é liberado **no OpenSIPS** (tabela `address`), e não na ACL do FreeSWITCH. A
`acl_lb_networks` não muda e o `reloadacl` não é necessário.

Arquivos deste diretório:

| Arquivo | Onde roda |
|---|---|
| `loadtest.conf` | .165: `/etc/flux-loadtest/loadtest.conf` |
| `preflight-165.sh` | .165 (somente leitura) |
| `preflight-sbc.sh` | .163 e .162 (somente leitura) |
| `fs-limites.sh` | .163 e .162: limites do FreeSWITCH em runtime (`mostrar`, `aplicar`, `restaurar`) |
| `sql/00-verificacao.sql` | Banco, nó 1 (somente leitura) |
| `sql/10-opensips-address-add.sql`, `sql/90-opensips-address-remove.sql` | Banco: libera ou remove o .165 como operadora |
| `sql/20-dids-create.sql`, `sql/95-dids-remove.sql` | Banco: massa de DIDs de teste |

## O que muda em produção

| Alteração | Onde | Risco | Reversão |
|---|---|---|---|
| Usuário `loadtest` + sudoers do `fs_cli`/`opensips-cli` | .163, .162 | Baixo (só leitura de status) | `userdel -r loadtest` e remover `/etc/sudoers.d/flux-loadtest` |
| `flux_monitor` + `/etc/mysql/flux-loadtest.cnf` | .161, .164 | Baixo (`PROCESS`, `REPLICATION CLIENT`) | `DROP USER 'flux_monitor'@'localhost'` e remover o cnf |
| .165 no grupo 10 da `address` + `address_reload` | Banco + .163 | **O .165 vira origem confiável no OpenSIPS** e pode chamar qualquer DID | `90-opensips-address-remove.sql` + `address_reload` |
| Conta de teste e DIDs `5500000xxxxxx` | Banco | CDR por chamada na conta de teste | `95-dids-remove.sql` e desativar a conta |
| `fsctl sps` / `fsctl max_sessions` | .163, .162 | **FreeSWITCH ativo com clientes:** limites maiores aceitam mais carga; se o servidor saturar, chamadas reais degradam | `fs-limites.sh restaurar` (ou restart do FS, que volta ao `switch.conf`) |
| Liberações de firewall, fail2ban e Event Guard para o .165 | .165, .163, .162 | Baixo | Remover as regras anotadas |
| Carga SIP | todos | **Tráfego real no mesmo OpenSIPS, FS e banco; a interface web divide CPU com o gerador** | Guard, degraus, Ctrl+C (parada suave) |

**Limites do FreeSWITCH:**
- **Hoje:** o `switch.conf` do Flux usa `sessions-per-second=30` e `max-sessions=1000` por FS.
- **Por que não cabem os cenários:** cada chamada de teste abre **2 sessões** (entrada mais bridge para o atendedor). Com os limites atuais, o teto dos dois nós somados é de ~30 CPS e ~1000 chamadas, divididos com o tráfego real. Acima disso, o FS responde 503, **inclusive para as chamadas de clientes**.
- **Na janela:** o `fs-limites.sh` sobe os limites em runtime, por degrau (seção 6), sem restart e sem alterar o `switch.conf`.

Faça o teste em horário de menor tráfego, com o responsável pelo ambiente e o NOC
acompanhando.

---

## 1. .165 (gerador)

### 1.1 Instalação

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare gen --dry-run
```

Revise o plano: pacotes `sip-tester`, `wrk`, `sysbench`, `expect` e utilitários, sysctl de buffers
UDP e limite de arquivos abertos. Nenhum serviço é instalado ou reiniciado. Aplique:

```bash
/opt/flux-loadtest/install/flux-host.sh prepare gen
```

### 1.2 Configuração

```bash
install -d -m 0750 /etc/flux-loadtest /var/lib/flux-loadtest/results
```

```bash
install -m 0640 /opt/flux-loadtest/deploy/stfc-completo/loadtest.conf /etc/flux-loadtest/loadtest.conf
```

Senha do event socket dos FS. A coleta usa uma senha só; se o .163 e o .162 tiverem senhas
diferentes, avise antes de seguir:

```bash
install -m 0600 /dev/null /etc/flux-loadtest/fs_cli.pass
```

```bash
read -r -s -p "Senha do event socket dos FS: " p && printf '%s\n' "$p" > /etc/flux-loadtest/fs_cli.pass && unset p
```

### 1.3 Firewall do .165

Com política `drop` na entrada, libere **vindo de 200.159.177.163 e 200.159.177.162**:

| Porta | Uso |
|---|---|
| `5060/udp` | Respostas do OpenSIPS ao originador |
| `5090/udp` | INVITE do bridge para o atendedor |
| `20000-27999/udp` | RTP do originador (`RTP_PORT_BASE`; 2 portas por chamada) |
| `40000-47999/udp` | RTP do atendedor (`UAS_RTP_PORT_BASE`; 2 portas por chamada) |

Anote as regras criadas para a reversão (seção 8).

### 1.4 Preflight (somente leitura)

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/preflight-165.sh
```

---

## 2. SBC: sbc-stfc-1 (.163) e sbc-stfc-02 (.162)

Nada é reinstalado nem reiniciado. Em cada SBC:

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

### 2.1 Preflight (somente leitura)

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/preflight-sbc.sh 200.159.177.165
```

Anote, de cada FS, os limites atuais e o pico de sessões e de sessões por segundo do tráfego
real (linhas `session(s)`). Eles definem a margem da seção 6. No .163 o preflight também
mostra a `address` carregada, o `lb_list` e a memória do OpenSIPS.

### 2.2 Usuário de coleta

No .163 (FreeSWITCH e OpenSIPS):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch opensips --dry-run
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch opensips
```

No .162 (só FreeSWITCH):

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch --dry-run
```

```bash
/opt/flux-loadtest/install/flux-host.sh prepare freeswitch
```

O `prepare` cria o usuário `loadtest` (sem senha; o acesso é pela chave do passo 5.1) e o
`/etc/sudoers.d/flux-loadtest`, validado com `visudo -cf` antes de gravar. Faz backup em
`/var/backups/flux-loadtest/<data>/`.

### 2.3 Rede e bloqueios

- **fail2ban do .163:** `200.159.177.165` em `ignoreip` do jail do SIP.
- **Event Guard do Flux:** whitelist do `200.159.177.165` pela interface. Sem isso, o volume de INVITE pode banir o gerador no meio do degrau.
- **Firewall do .163:** entrada de `200.159.177.165` em `5060/udp`.
- **Firewall dos dois FS:**
  - entrada de `200.159.177.165` na faixa de RTP do FS (mostrada pelo preflight);
  - saída para o .165 nas portas da tabela 1.3.

---

## 3. Bancos (.161 e .164): coleta passiva

Senha do `flux_monitor`, igual nos dois nós (alfanumérica, 12 caracteres ou mais):

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

---

## 4. Conta, DIDs e liberação no OpenSIPS

### 4.1 Conferência (somente leitura, no .161)

```bash
cd /opt/flux-loadtest/deploy/stfc-completo/sql && mysql flux < 00-verificacao.sql
```

O bloco 5 precisa sair vazio (nenhum DID na faixa `5500000`). No bloco 1, o `.165` ainda não
deve aparecer.

### 4.2 Conta e DID modelo (pela interface do Flux)

1. **Conta de teste:**
   - ativa, pós-paga, **sem tarifa** (rate group de custo zero);
   - `credit_limit` alto;
   - `maxchannels` = 0 (sem limite).

   Anote o `accounts.id`.
2. **DID modelo nessa conta:**
   - número `5500000000000`, tipo **DIRECT-IP**;
   - destino `200.159.177.165:5090`;
   - sem `maxchannels`.

Confira (troque `<ID>`):

```bash
{ echo "SET @conta = <ID>;"; cat 00-verificacao.sql; } | mysql flux
```

Blocos 4 e 5: conta ativa e sem limite de canais; 1 DID na faixa, `call_type` 2, destino
`200.159.177.165:5090`.

### 4.3 Massa de DIDs (escrita no banco, no .161)

O `20-dids-create.sql` clona o DID modelo (todas as colunas, exceto `id` e `number`).
Primeiro, um lote de validação com 10 DIDs:

```bash
{ echo "SET @conta = <ID>; SET @inicio = 1; SET @lote = 10;"; cat 20-dids-create.sql; } | mysql flux
```

Esperado: `modelo_ok = 1` e `inseridos = 10`. Depois os lotes de 10.000, um por vez (números já
criados são pulados):

```bash
for i in 1 10001 20001 30001 40001 50001 60001 70001 80001 90001; do { echo "SET @conta = <ID>; SET @inicio = $i;"; cat 20-dids-create.sql; } | mysql flux || break; done
```

Total esperado na faixa: 100.000 (o modelo mais `5500000000001` a `5500000099999`).

### 4.4 Lista para o gerador

No .161, gere a lista e copie para o .165 em `/etc/flux-loadtest/dids.txt` (0644):

```bash
mysql -N -B -e "SELECT number FROM dids WHERE accountid = <ID> AND status = 0 AND call_type = 2 AND extensions = '200.159.177.165:5090' AND number LIKE '5500000%'" flux > /root/dids.txt
```

```bash
scp /root/dids.txt root@200.159.177.165:/etc/flux-loadtest/dids.txt
```

### 4.5 Liberar o .165 no OpenSIPS (escrita no banco + reload no .163)

No .161:

```bash
mysql flux < 10-opensips-address-add.sql
```

No .163 (recarrega só a tabela `address`; sem restart):

```bash
opensips-cli -x mi address_reload
```

```bash
opensips-cli -x mi address_dump | grep -B2 -A6 200.159.177.165
```

---

## 5. Chaves, check e smoke (no .165)

### 5.1 Chaves SSH da coleta

Com um usuário administrativo com sudo nos 4 servidores (pede a senha dele uma vez por
servidor; a chave entra com `from=200.159.177.165`, sem PTY e sem encaminhamentos):

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh keys setup --via admin --write-config -c /etc/flux-loadtest/loadtest.conf
```

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh check -c /etc/flux-loadtest/loadtest.conf
```

No `check`: os dois FS `is ready`, `lb_list` com os dois nós, cluster com 2 nós `Synced`,
atendedor com a porta 5090 livre.

### 5.2 Smoke (com os limites atuais do FS)

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh smoke --media none --did 5500000000001 -c /etc/flux-loadtest/loadtest.conf
```

Esperado: "Concluidas com sucesso 1" e "Chamadas recebidas do FS 1". Depois, no .161:

```bash
{ echo "SET @conta = <ID>;"; cat /opt/flux-loadtest/deploy/stfc-completo/sql/00-verificacao.sql; } | mysql flux
```

Bloco 6: `ANSWER`, débito e custo **zero**. Se houver débito, pare: a conta tem tarifa.

| Resultado do smoke | Causa provável |
|---|---|
| 403 | .165 fora da `address` carregada (4.5) ou bloqueado pelo Event Guard |
| 404/480 | DID fora da massa ou não DIRECT-IP |
| 503 | `load_balancer` sem nó disponível ou limite de sessões do FS |
| "Chamadas recebidas do FS 0" com 408/502 | Firewall do .165 (1.3) ou saída dos FS para o .165 (2.3) |

---

## 6. Degraus

Antes de cada degrau, ajuste os limites **nos dois FS** com os valores da tabela. Eles são por
nó, considerando o `load_balancer` dividindo a carga ao meio e as 2 sessões por chamada, mais uma
margem para o tráfego real. A margem precisa ser de pelo menos 2 vezes o pico real anotado no 2.1:
50 sessões por segundo e 500 sessões na tabela; aumente se o pico real for maior.

| # | Degrau | Comando (`run ... -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip`) | `fs-limites.sh aplicar` |
|---|---|---|---|
| 0 | piloto | `-r 10 -H 10 -w 60 -M none --label stfc-piloto` (limites atuais) | — |
| 1 | 1000 simultâneas | `-r 100 -H 10 -w 300 -M none --label stfc-c1000-cps100` | `150 1500` |
| 2 | 2000 simultâneas | `-r 100 -H 20 -w 300 -M none --label stfc-c2000-cps100` | `150 2500` |
| 3 | 3000 simultâneas | `-r 100 -H 30 -w 300 -M none --label stfc-c3000-cps100` | `150 3500` |
| 4 | 200 CPS | `-r 200 -H 15 -w 300 -M none --label stfc-c3000-cps200` | `250 3500` |
| 5 | 300 CPS | `-r 300 -H 10 -w 300 -M none --label stfc-c3000-cps300` | `350 3500` |
| 6 | mídia | o maior degrau sem limite atingido, com `-M rtp` e o rótulo terminado em `-rtp` | o mesmo do degrau |

Exemplo do degrau 1 (em cada FS):

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh aplicar 150 1500
```

O `load_balancer` lê a capacidade dos FS pelo heartbeat do event socket
(`fetch_freeswitch_stats`). Cerca de 30 s depois de aplicar, confira no .163 que o `max` dos
dois nós subiu; sem isso, o OpenSIPS responde 503 antes do FS:

```bash
opensips-cli -x mi lb_list | grep -E '"(uri|max|load)"'
```

No .165:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip -r 100 -H 10 -w 300 -M none --label stfc-c1000-cps100
```

O comando pede a palavra `PRODUCAO`. Para ver o plano sem executar, troque `--confirm-prod` por
`--dry-run`. Cada degrau leva de 10 a 12 minutos (baseline, janela, drenagem e cooldown).

Leia o `report.txt` (`/var/lib/flux-loadtest/results/<data>-<rótulo>/`) antes do degrau seguinte.
**Não suba** se houver:
- falhas SIP acima de 1%, ou "Originadas que não chegaram" acima de 0;
- respostas 503 (limite do FS ou `load_balancer`);
- CPU de algum SBC acima de 70%, ou do .165 acima de 60%;
- `udp_rcvbuf_err_s` nos SBC ou flow control no PXC;
- reclamação de clientes ou alerta do NOC.

O guard interrompe sozinho nos limites do `loadtest.conf`: CPU 75% nos servidores e 70% no
gerador, memória 85%, falhas 2%, cluster. Ctrl+C uma vez faz parada suave; duas vezes, imediata.

Os limites do FS ficam aplicados entre os degraus. Se a janela acabar ou o teste parar, vá
direto para a seção 8.

---

## 7. Ordem de execução

| # | Onde | Passo |
|---|---|---|
| 1 | .165, .163, .162, .161 | Preflights e `00-verificacao.sql` (somente leitura) |
| 2 | .165 | 1.1 a 1.3: instalação, configuração, firewall |
| 3 | .163, .162 | 2.2 usuário de coleta; 2.3 fail2ban, Event Guard, firewall |
| 4 | .161, .164 | 3: coleta do MySQL |
| 5 | Interface + .161 | 4.2 a 4.4: conta, DID modelo, massa, lista |
| 6 | .161 + .163 | 4.5: liberação no OpenSIPS |
| 7 | .165 | 5: chaves, `check`, smoke, conferência do CDR |
| 8 | .165 + FS | 6: degraus 0 a 6, com `fs-limites.sh aplicar` antes de cada um |
| 9 | todos | 8: reversão |

## 8. Reversão (ao fim ou ao abortar)

Primeiro os limites do FS (em cada FS):

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh restaurar
```

Depois a liberação no OpenSIPS (no .161 e no .163):

```bash
mysql flux < /opt/flux-loadtest/deploy/stfc-completo/sql/90-opensips-address-remove.sql
```

```bash
opensips-cli -x mi address_reload
```

DIDs de teste (no .161; repita até `removidos = 0`):

```bash
{ echo "SET @conta = <ID>;"; cat /opt/flux-loadtest/deploy/stfc-completo/sql/95-dids-remove.sql; } | mysql flux
```

Depois:
- desative a conta de teste pela interface;
- no .165, remova as chaves de coleta dos servidores:

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh keys revoke -c /etc/flux-loadtest/loadtest.conf
```

- desfaça as liberações de firewall, fail2ban e Event Guard do .165;
- guarde os pacotes `/var/lib/flux-loadtest/results/*.tar.gz` para a análise.

Os backups de cada `prepare` ficam em `/var/backups/flux-loadtest/<data>/` no servidor onde
ele rodou. O usuário `loadtest` e o `flux_monitor` podem ficar para próximas campanhas, ou ser
removidos como na tabela do início.
