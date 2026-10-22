# Teste de carga do STFC: resultados de 21/10/2026 (WEB-1437)

Campanha nos servidores de produção, com tráfego real, seguindo o runbook deste diretório
(`README.md`). Ela parou no degrau de 25 CPS: a investigação de um atraso concentrado no
sbc-stfc-02 está em andamento (achado A1). Os números de capacidade abaixo são medidos até 25 CPS;
acima disso, são projeções lineares.

## 1. Escopo

| Servidor | IP público | IP interno | Papel no teste |
|---|---|---|---|
| sbc-stfc-interfaceweb | 200.159.177.165 | 172.17.4.165 | Gerador (SIPp originador + atendedor DIRECT-IP) e coletor local |
| sbc-stfc-1 | 200.159.177.163 | 172.17.4.163 | OpenSIPS 3.6.8 + FreeSWITCH 1.11.3 (fs1) |
| sbc-stfc-02 | 200.159.177.162 | 172.17.4.162 | FreeSWITCH 1.11.3 (fs2) |
| banco-master-sbc-stfc | 200.159.177.161 | 172.17.4.161 | Percona XtraDB Cluster, nó com o VIP 172.17.4.100 |
| banco-slave-stfc | 200.159.177.164 | 172.17.4.164 | Percona XtraDB Cluster |

Caminho de cada chamada de teste, o mesmo das chamadas reais de operadora:

```
.165 SIPp :5060 -INVITE-> OpenSIPS .163:5060 (address grupo 10)
  -> load_balancer grupo 1 -> FS .163:5070 ou FS .162:5070 (dialplan Lua, DID no MySQL pelo VIP)
  -> bridge DIRECT-IP, que sai pelo OpenSIPS (record_route) -> atendedor .165:5090
```

Massa de teste:
- **Conta:** 211, sem tarifa, `credit_limit` 10.000.000, `maxchannels` 0.
- **DIDs:** 100.000 DIRECT-IP, de `5500000000000` a `5500000099999` (DDD 00, fictício), com destino `200.159.177.165:5090`.
  - todos clonados do DID modelo (id 83663, produto 83673);
  - modelo com `bypass_media=0` e `leg_timeout=30`.

Ferramentas:
- `flux-loadtest.sh` (`smoke`, `run`), com coleta somente leitura por SSH nos 5 servidores;
- `pdd-pcap.py`, que mede o atraso a partir da captura SIP do gerador.

## 2. Alterações em produção ainda ativas

| Alteração | Onde | Reversão |
|---|---|---|
| Usuário `loadtest` (sem senha) + `/etc/sudoers.d/flux-loadtest` (`fs_cli`, `opensips-cli`) | .163, .162 | `userdel -r loadtest`; remover o sudoers (backup em `/var/backups/flux-loadtest/`) |
| `flux_monitor@localhost` (`PROCESS`, `REPLICATION CLIENT`) + `/etc/mysql/flux-loadtest.cnf` | .161 (usuário, replicado), .161/.164 (cnf) | `DROP USER 'flux_monitor'@'localhost'`; remover o cnf |
| Chave SSH do .165 no `authorized_keys` do `loadtest` (`from=200.159.177.165`) | .163, .162, .161, .164 | `flux-loadtest.sh keys revoke` |
| `/root/.fs_cli_conf` (senha do event socket, 0600) | .163, .162 | Pode ficar (uso do root); remover se não for desejado |
| Regra `iptables -I INPUT -s 200.159.177.165/32 -p udp ... flux-loadtest -j ACCEPT` (não persistente) | .162 (confirmar no .163) | `iptables -D INPUT -s 200.159.177.165/32 -p udp -m comment --comment flux-loadtest -j ACCEPT` |
| `address` id 19: grupo 10, `200.159.177.165`, `context_info='flux-loadtest'` | Banco + `address_reload` no .163 | `sql/90-opensips-address-remove.sql` + `address_reload` |
| Conta 211 e 100.000 DIDs `5500000xxxxxx` | Banco | `sql/95-dids-remove.sql` (clones, em lotes); modelo e conta pela interface (o produto 83673 sai junto) |
| Pacotes do gerador, `/etc/sysctl.d/90-flux-loadtest.conf`, `/etc/security/limits.d/90-flux-loadtest.conf` | .165 | Podem ficar; `apt purge sip-tester wrk sysbench` e remover os dois arquivos se não forem mais usados |
| Capturas SIP `/root/smoke-sip.pcap`, `/root/smoke-sip2.pcap`, `/root/degrau-cps25.pcap` | .165 | Apagar depois da análise (contêm DIDs e cabeçalhos SIP) |
| `fs-limites.sh` | — | **Não aplicado**: os limites do FS estão como no `switch.conf` |

## 3. Execuções

### 3.1 Smokes

| Smoke | Resultado | INVITE -> 200 |
|---|---|---|
| DIDs `5500000000001` e `...02` | Originador ok; o atendedor **não recebeu ACK nem BYE** (perna B presa no FS até os timers) | 168 e 104 ms |
| DID `5500000000003`, com o atendedor corrigido (A8) | ACK 19 ms depois do 200, BYE 26 ms depois do BYE do originador; CDR `NORMAL_CLEARING`, débito e custo 0 | 144 ms |

### 3.2 Degraus

Todos com `-t sip -M none` (sem RTP), alvo pelo OpenSIPS e limites do FS inalterados. "Pico" é o
pico das amostras de 5 s na fase `sip`.

| | `stfc-piloto` | `stfc-c500-cps25` | `stfc-cps25-pcap` |
|---|---|---|---|
| Comando | `-r 10 -H 10 -w 60` | `-r 25 -H 20 -w 180` | `-r 25 -H 20 -w 120` (com captura) |
| Chamadas (sucesso/criadas) | 208/208 | 3079/3079 | 1576/1576 |
| Atendedor (recebidas/encerradas) | 208/208 | 3079/3079 | 1576/1576 |
| Pico de simultâneas | 69 | 641 | 504 |
| Pico de CPS | 6 | 25,0 | 24,2 |
| INVITE -> 200 (média) | **134 ms** | **1773 ms** | **378 ms** |
| CPU .163 (OpenSIPS + fs1), pico | 12% | 39% | 26% |
| CPU .162 (fs2), pico | 4% | 19% | 11% |
| CPU .161 (banco), pico | 11% | 32% | 27% |
| `mysqld` .161, pico (100 = 1 núcleo) | 60 | 216 | 173 |
| Consultas/s .161 (média/pico) | 746/1363 | 3538/5776 | 2589/4901 |
| Diálogos no OpenSIPS (pico) | 59 | 510 | 430 |
| Memória compartilhada do OpenSIPS (pico) | 9,4% | 27,6% | 19,6% |
| Gerador .165, pico | 7% | 3% | 3% |
| Limites do guard | nenhum | nenhum | nenhum |

Em todos os degraus: PXC `Synced`, sem flow control, sem fila de replicação, `+0` consulta lenta,
`udp_rcvbuf_err` 0 em todos os servidores e nenhuma resposta 4xx/5xx.

### 3.3 Atraso por FreeSWITCH (`pdd-pcap.py`, degrau `stfc-cps25-pcap`)

"Ida": do INVITE do originador até o bridge chegar ao atendedor. "Volta": do 200 do atendedor
até o 200 chegar ao originador.

| FS | Chamadas | Ida p50/p90/p99 | Volta p50/p90/p99 | Total p50/p90/p99/máx |
|---|---|---|---|---|
| .163:5070 | 745 | 74/88/102 ms | 23/43/70 ms | 103/123/152/175 ms |
| .162:5070 | 831 | 121/441/1151 ms | 77/**1546**/3062 ms | 207/**2049**/3803/5376 ms |

O total p90 por faixa de 20 s sobe com a carga: 161 ms (3 CPS), 232 ms (15 CPS), 1372 ms
(19 CPS), 2505 ms (23 CPS).

## 4. Achados

### A1. Atraso pós-discagem concentrado no sbc-stfc-02 (.162)
- **Evidência:**
  - Tabela 3.3: o .163 responde em ~100 ms até 25 CPS; o .162 tem p90 de 2 s e máximo de 5,4 s.
  - Os valores da volta (p90 1,5 s, máximo 4,9 s) e da ida (p99 1,15 s) caem nos degraus de retransmissão SIP sobre UDP (T1 = 500 ms: 0,5, 1,5, 3,5 s). Isso indica **pacote descartado e recuperado por retransmissão**, não processamento lento.
- **Descartado:**
  - CPU do FS do .162 (6% de média);
  - banco e OpenSIPS (os mesmos do .163);
  - rede: ping do .162 ao .163 com 0% de perda e 0,97 ms;
  - `udp_rcvbuf_err` 0;
  - conntrack em 155 de 262.144;
  - erros de handle ou ODBC no log do FS.
- **Suspeita atual (firewall do .162):**
  - política `INPUT DROP`, com 13.283 pacotes descartados;
  - a cadeia `defferrari` recebe todo o tráfego novo (4,9 milhões de pacotes) **antes** das regras de `ACCEPT` por origem;
  - não foi vista regra explícita para o OpenSIPS (`200.159.177.163`) na 5070. Sem ela, o SIP do OpenSIPS para o .162 depende de o fluxo já estar no conntrack.
- **Impacto:** o mesmo atraso atinge as chamadas reais que o `load_balancer` envia ao .162, e cresce com a carga.
- **Próximo passo:** ver a cadeia `defferrari` e os contadores da política `DROP` antes e depois de chamadas de teste. Qualquer mudança no firewall do .162 precisa de análise de impacto antes.

### A2. Banco: ~240 consultas por chamada
- **Evidência:**
  - ~250 consultas por chamada no piloto e ~240 a 25 CPS, das quais ~37 UPDATE e ~6 INSERT;
  - a 25 CPS: 5,8 mil consultas/s no pico, `mysqld` em 2,2 núcleos e 13 MB/s de escrita nos dois nós.
- **Projeção (linear):** CPU do .161 em 75% (guard) por volta de **60 CPS**; ~24 mil consultas/s a 100 CPS. O banco é o mesmo do tráfego real.
- **Recomendação:** levantar no `performance_schema` (`events_statements_summary_by_digest`) quais consultas o dialplan Lua e o `xml_curl` repetem por chamada, e o que pode ir para cache.

### A3. Memória compartilhada do OpenSIPS
- **Evidência:** de 5,9% para 27,6% com 510 diálogos e 656 transações, ou seja, ~0,04% por diálogo, num total de ~64 MB.
- **Projeção:** ~50% com 1000 diálogos, ~70% com 1500, ~92% com 2000. Os cenários de 2000 e 3000 simultâneas **não cabem**.
- **Risco:** com a memória compartilhada esgotada, o OpenSIPS falha para todas as chamadas. O guard do flux-loadtest **não** vigia esse indicador; no teste, ele foi acompanhado à mão (`get_statistics shmem:`).
- **Recomendação:** aumentar o `-m` do OpenSIPS (ex.: 256 MB). Exige restart do OpenSIPS em produção, numa janela própria.

### A4. CPU do sbc-stfc-1 (OpenSIPS e FS no mesmo servidor)
- **Evidência:** 39% de pico a 25 CPS (`freeswitch` até 1,4 núcleo, `opensips` até 0,12), contra 19% no .162.
- **Projeção:** ~75% por volta de **50 CPS**. O .163 tem a carga do FS mais a do OpenSIPS, que roteia todas as chamadas dos dois FS.

### A5. Configuração diferente entre os FreeSWITCH
`switch.conf`:

| FS | `sessions-per-second` | `max-sessions` | `max-db-handles` | `db-handle-timeout` |
|---|---|---|---|---|
| .163 | 300 | 2000 | 50 | 10 |
| .162 | 50 | 2000 | 500 | 30 |

- **Impacto:** com bridge para o atendedor, cada chamada abre 2 sessões. O .162 aguenta só ~25 CPS de teste e o .163 ~150, mas o `load_balancer` distribui por carga, não por esses limites.
- **Observação:** não houve erro de handle no .163, mesmo com 50.
- **Recomendação:** igualar os dois nós. Exige restart do FS.

### A6. Chamadas recusadas no sbc-stfc-02
O perfil `default` do .162 registra 104.440 chamadas de entrada desde o boot, 104.326 com falha
(99,9%). No .163 são 859, com 668 falhas. Tudo indica varredura SIP ou desafios de autenticação.
Vale entender antes de concluir o A1.

### A7. Log do FreeSWITCH
O Lua do Flux grava as consultas em ERR/WARNING: `[IS_VALID_DID] Query` 3 vezes por chamada e
`[xml_handler] Params`. No degrau de 25 CPS foram ~2.900 linhas no .163 e ~2.400 no .162 em 4
minutos, quase todas desse tipo. Isso esconde erros reais e custa disco em carga alta.
**Recomendação:** passar esses logs para DEBUG no Lua.

### A8. Bridge DIRECT-IP passa pelo OpenSIPS em produção
- **O que aconteceu:**
  - em produção, o FS envia a perna B pelo OpenSIPS, que faz `record_route`;
  - o atendedor do flux-loadtest não devolvia o `Record-Route`;
  - o FS ficava sem route set, então ACK e BYE não chegavam, e a perna B ficava presa até os timers.
- **Por que o lab não pegou:** no laboratório, o FS fazia o bridge direto.
- **Corrigido:** `scenarios/uas-answer.xml.in` (#8).

### A9. Padrões do DID criado pela interface
O DID modelo veio com `bypass_media=1` e `leg_timeout=0`. Com bypass, o RTP iria direto entre
originador e atendedor (no próprio .165) e o teste não mediria mídia nos FS. Os dois foram
ajustados no modelo (`bypass_media=0`, `leg_timeout=30`) antes da clonagem. Vale conferir esses
padrões nos DIDs reais.

### A10. Estado do banco do STFC
- **ACL e `load_balancer`:**
  - `system.opensips = 1`, `opensips_domain = 127.0.0.1`;
  - não existe `acl_lb_networks`;
  - `load_balancer`: grupo 1 com os dois FS (`.162` e `.163` na 5070, recurso `fs://...:8021`) e grupo 2 com `200.159.177.160:5060` (gateway de saída, fora do teste).
- **Tarifa:** os CDRs da conta 211 têm débito e custo zero, mesmo com `reverse_rate=1` e `rate_group=1` no DID.
- **Collation:** a tabela `address` está em `utf8mb4_general_ci` e `dids.number` em `utf8`. Variáveis de sessão no padrão do 8.4 (`utf8mb4_0900_ai_ci`) falham contra a primeira e anulam o índice da segunda (A13).

### A11. Senha do event socket exposta
Durante o diagnóstico do `fs_cli`, a senha do event socket (a mesma nos dois FS, e também nos
`resources` do `load_balancer`) foi exibida no terminal. **Recomendação:** trocar depois da
campanha nos dois FS e atualizar a tabela `load_balancer` (`lb_reload`), na mesma janela.

### A12. Do laboratório (detalhes em `lab/README.md`)
- DID para ramal **não registrado** não chega à caixa postal: o `flux-sipdevice-routing.lua` desliga antes do `leave_voicemail` e a chamada termina em 480.
- DID para ramal **registrado** depende do nó: o REGISTER fica no FS escolhido pelo `dispatcher`, mas o `load_balancer` distribui as chamadas sem saber disso.

### A13. Problemas do runbook encontrados em produção (corrigidos)
- **Collation dos SQL:** "Illegal mix of collations" (#7).
- **`fs-limites.sh`:** baixaria o `sps` do .163 de 300 para 150; agora nunca reduz um limite (#7).
- **`/root/.fs_cli_conf`:** precisa do formato `[default]` + `password => ...`.
- **Criação de DIDs:** varria a tabela `dids` por número gerado (collation anulando o índice) e não terminava no segundo lote. Reescrita para usar a chave primária e o índice de `accountid` (#9).

## 5. Capacidade

| Limite | Medido (25 CPS) | Onde estoura (projeção linear) |
|---|---|---|
| Atraso no .162 (A1) | p90 de 2 s e máximo de 5,4 s | Já degradado a 20 CPS |
| CPU do .163 (A4) | 39% | ~50 CPS |
| CPU do banco (A2) | 32% | ~60 CPS |
| Memória do OpenSIPS (A3) | 27,6% com 510 diálogos | ~2000 diálogos |
| Limite do FS .162 (A5) | `sps` 50 | ~25 CPS de teste sem `fs-limites.sh` |

- Os alvos da issue (100, 200 e 300 CPS; 1000, 2000 e 3000 simultâneas) **não cabem na infraestrutura atual**.
- Resolvido o A1, o teto provável fica entre 50 e 60 CPS (CPU do .163 e do banco) e por volta de 1500 simultâneas (memória do OpenSIPS).
- As projeções partem de medidas até 25 CPS e precisam ser confirmadas em degraus.

## 6. Correções no repositório durante a campanha

| PR | Mudança |
|---|---|
| #6 | Runbook do teste completo (`deploy/stfc-completo/`) |
| #7 | Collation dos SQL, `fs-limites.sh` sem reduzir limites, preflight com `listen-ip` do event socket, limites reais dos FS no README |
| #8 | Atendedor devolve o `Record-Route` no 180 e no 200 |
| #9 | Criação de DIDs pelos índices (chave primária e `accountid`) |
| #10 | `pdd-pcap.py` |

## 7. Pendências e decisões

1. **A1 (bloqueia os próximos degraus):** diagnosticar e corrigir o descarte no .162.
   - mostrar a cadeia `defferrari`;
   - ler os contadores da política `DROP` antes e depois de chamadas;
   - avaliar a liberação mínima do OpenSIPS (.163) na 5070.
2. **Depois do A1:** degrau de 40 CPS (`-r 40 -H 20`), com `fs-limites.sh aplicar 100 1500` e parada se INVITE -> 200 passar de 3 s ou a memória do OpenSIPS passar de 60%.
3. **Decisões do responsável pelo ambiente (todas com restart):**
   - `-m` do OpenSIPS (A3);
   - igualar o `switch.conf` dos FS (A5);
   - nível de log do Lua (A7).
4. **Senha do event socket:** trocar nos dois FS e atualizar o `load_balancer` (A11).
5. **Banco:** investigar as ~240 consultas por chamada (A2).
6. **Ao fim da campanha:** reversão da seção 2 e da seção 8 do `README.md`.
