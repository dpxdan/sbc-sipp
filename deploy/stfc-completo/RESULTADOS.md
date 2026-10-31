# Teste de carga do STFC: resultados de 21/10/2026 (WEB-1437)

Campanha nos servidores de produção, com tráfego real, seguindo o runbook deste diretório
(`README.md`). Todas as metas da issue foram executadas ou avaliadas até o fim da janela
(23:51), com a configuração de produção (limites do FS inalterados).

Em 22/10/2026 os resultados foram levados ao Zabbix de produção (dashboard, envio ao vivo e
disparo de perfis pelo menu, seção 7) e foi criado o script de limpeza dos DIDs de teste
(`dids-limpar.sh`).

## Resumo

### Resultado por meta

| Meta | Resultado | Medido | O que limitou |
|---|---|---|---|
| 1000 simultâneas | **Atingida** | 1022 simultâneas, 1515/1515 chamadas, 0 falha, INVITE -> 200 de 145 ms | — |
| 2000 simultâneas | **Parcial** | 1962 simultâneas; 7,3% de falha no fim da subida (guard) | `max-sessions` 2000 por FS: o .162 chegou a 2000 sessões (`503 Maximum Calls In Progress`) e o `load_balancer` ficou sem destino (`503 No FreeSWITCH Available`) (A14) |
| 3000 simultâneas | **Não atingível** com a configuração atual (não executada) | — | Teto de ~2000 chamadas: 2 FS x 2000 sessões / 2 sessões por chamada, já contando o tráfego real (A14) |
| 100 CPS | **Não atingida** | A rampa chegou a 50 CPS; falhas a partir de 40-50 CPS (10,7% no total), INVITE -> 200 médio de 4,6 s | Fila de mensagens SIP no FS do .162 (A1) e `load_balancer` sem destino (A15) |
| 200 e 300 CPS | **Não atingíveis** (não executadas) | — | O sistema não sustenta 100 CPS |
| CPS sustentável hoje | **~20 CPS** | Até 15 CPS: total p90 de ~170 ms; 19 CPS: 436 ms; 23 CPS: 2 s; 25 CPS sustentado: .162 com total p50 de 4,7 s | A1 |
| 100 mil DIDs | **Atingida** | 100.000 DIDs DIRECT-IP em uso nos testes, sem impacto no roteamento (~100 ms) | — |

### Gargalos, em ordem

1. **Processamento SIP do FreeSWITCH do .162 (A1), a partir de ~20 CPS no sistema.** O .162 recebe
   todas as mensagens, mas demora para tratá-las: o 100 Trying passa de ~10 ms para 0,5 a 1,8 s a
   25 CPS, e o ACK do 200 de 1 a 4 s. O OpenSIPS retransmite e o atraso cresce com o tempo. A causa
   raiz ainda não está confirmada (suspeitos: `sps` 50 e o banco interno SQLite, ambos só no .162).
2. **`max-sessions` 2000 por FS (A14):** teto de ~1000 chamadas por FS e ~2000 no sistema.
3. **`load_balancer` sem destino sob estresse (A15):** `503 No FreeSWITCH Available` já com 716
   simultâneas a 40-50 CPS, bem abaixo da capacidade.

Não são gargalo nas cargas medidas: rede e firewall, CPU (.163 em 39% a 50 CPS), banco (31% a 50
CPS), memória do OpenSIPS (22% com 1962 diálogos; a projeção anterior estava errada, A3) e o
dialplan Lua com o banco (~100 ms constantes).

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

Cada chamada abre 2 sessões no FS que a atende (perna A e perna B do bridge).

Massa de teste:
- **Conta:** 211, sem tarifa, `credit_limit` 10.000.000, `maxchannels` 0.
- **DIDs:** 100.000 DIRECT-IP, de `5500000000000` a `5500000099999` (DDD 00, fictício), com destino `200.159.177.165:5090`.
  - todos clonados do DID modelo (id 83663, produto 83673);
  - modelo com `bypass_media=0` e `leg_timeout=30`.

Ferramentas:
- `flux-loadtest.sh` (`smoke`, `run`), com coleta somente leitura por SSH nos 5 servidores;
- `pdd-pcap.py`, que mede o atraso a partir da captura SIP do gerador;
- captura no .163 (`tcpdump` na 5070 com o .162) e `nstat` antes e depois, para comparar o que o
  OpenSIPS enviou com o que o .162 recebeu.

## 2. Alterações em produção ainda ativas

| Alteração | Onde | Reversão |
|---|---|---|
| Usuário `loadtest` (sem senha) + `/etc/sudoers.d/flux-loadtest` (`fs_cli`, `opensips-cli`) | .163, .162 | `userdel -r loadtest`; remover o sudoers (backup em `/var/backups/flux-loadtest/`) |
| `flux_monitor@localhost` (`PROCESS`, `REPLICATION CLIENT`) + `/etc/mysql/flux-loadtest.cnf` | .161 (usuário, replicado), .161/.164 (cnf) | `DROP USER 'flux_monitor'@'localhost'`; remover o cnf |
| Chave SSH do .165 no `authorized_keys` do `loadtest` (`from=200.159.177.165`) | .163, .162, .161, .164 | `flux-loadtest.sh keys revoke` |
| `/root/.fs_cli_conf` (senha do event socket, 0600) | .163, .162 | Pode ficar (uso do root); remover se não for desejado |
| Regra `iptables -I INPUT -s 200.159.177.165/32 -p udp ... flux-loadtest -j ACCEPT` (não persistente) | .162 (confirmar no .163) | `iptables -D INPUT -s 200.159.177.165/32 -p udp -m comment --comment flux-loadtest -j ACCEPT` |
| `address` id 19: grupo 10, `200.159.177.165`, `context_info='flux-loadtest'` | Banco + `address_reload` no .163 | `sql/90-opensips-address-remove.sql` + `address_reload` |
| Conta 211 e 100.000 DIDs `5500000xxxxxx` | Banco | `dids-limpar.sh contar` e `remover --conta 211` no .161 (99.999 clones, em lotes); DID modelo e conta pela interface (o produto 83673 sai junto) |
| Pacotes do gerador, `/etc/sysctl.d/90-flux-loadtest.conf`, `/etc/security/limits.d/90-flux-loadtest.conf` | .165 | Podem ficar; `apt purge sip-tester wrk sysbench` e remover os dois arquivos se não forem mais usados |
| Capturas SIP: `/root/smoke-sip*.pcap`, `/root/degrau-cps25*.pcap` (.165); `/root/sip-163*.pcap` (.163) | .165, .163 | Apagar depois da análise (contêm DIDs e cabeçalhos SIP) |
| Arquivos de diagnóstico `/root/net-*`, `/root/nstat-*`, `/root/rede-*`, `/root/fs-db-*`, `/root/tcpdump-*` | .163, .162; `/root/db-origens.txt` no .161 | Apagar |
| `fs-limites.sh` | — | **Não aplicado**: os limites do FS estão como no `switch.conf` |
| `ZABBIX_*` no `loadtest.conf` e `/etc/flux-loadtest/zabbix_api.token` | .165 | Esvaziar `ZABBIX_SERVER` (para o envio ao vivo); revogar o token e apagar o arquivo |
| Include `/etc/zabbix/zabbix_agentd.conf.d/flux-loadtest.conf`, `/usr/local/sbin/flux-loadtest-zbx`, `/etc/sudoers.d/flux-loadtest-zbx`, perfis em `/etc/flux-loadtest/profiles.d/` | .165 | Remover os quatro e reiniciar o `zabbix-agent` (que já existia e fica). Backup: `/var/backups/flux-loadtest/20261022-024752` |
| Hosts `flt-*`, dashboard, scripts do menu `Flux Loadtest` e manutenção `Flux Loadtest - sem alertas ao suporte` | Zabbix de produção | `ZABBIX.md`, seção Reversão |

## 3. Execuções

Todas com `-t sip -M none` (sem RTP), alvo pelo OpenSIPS e limites do FS inalterados. "Pico" é o
pico das amostras de 5 s na fase `sip`.

### 3.1 Smokes

| Smoke | Resultado | INVITE -> 200 |
|---|---|---|
| DIDs `5500000000001` e `...02` | Originador ok; o atendedor **não recebeu ACK nem BYE** (perna B presa no FS até os timers) | 168 e 104 ms |
| DID `5500000000003`, com o atendedor corrigido (A8) | ACK 19 ms depois do 200, BYE 26 ms depois do BYE do originador; CDR `NORMAL_CLEARING`, débito e custo 0 | 144 ms |

### 3.2 Degraus de CPS (diagnóstico)

| | `stfc-piloto` | `stfc-c500-cps25` | `stfc-cps25-pcap` | `stfc-ipt-cps10` | `stfc-cps25-rede` | `stfc-cps25-rede2` |
|---|---|---|---|---|---|---|
| Comando | `-r 10 -H 10 -w 60` | `-r 25 -H 20 -w 180` | `-r 25 -H 20 -w 120` | `-r 10 -w 60` | `-r 25 -H 20 -w 90` | `-r 25 -H 20 -w 240` |
| Chamadas (sucesso/criadas) | 208/208 | 3079/3079 | 1576/1576 | 208/208 | 908/908 | 4546 completas |
| Pico de CPS | 6 | 25,0 | 24,2 | 6 | 18 | 25 (~2 min) |
| Pico de simultâneas | 69 | 641 | 504 | — | 366 | — |
| INVITE -> 200 (média) | **134 ms** | **1773 ms** | **378 ms** | **131 ms** | **147 ms** | .162: p50 **4,7 s**; .163: p50 108 ms |
| CPU .163 (OpenSIPS + fs1), pico | 12% | 39% | 26% | — | 23% | — |
| CPU .162 (fs2), pico | 4% | 19% | 11% | — | 10% | — |
| CPU .161 (banco), pico | 11% | 32% | 27% | — | 22% | — |
| Consultas/s .161 (média/pico) | 746/1363 | 3538/5776 | 2589/4901 | — | 2070/3857 | — |
| Memória compartilhada do OpenSIPS (pico) | 9,4% | 27,6% | 19,6% | — | 16,4% | — |

A rampa padrão (10% do alvo, +10% a cada 10 s) só chega a 25 CPS depois de ~115 s; por isso os
degraus de 60 e 90 s não reproduziram o atraso. Em todos: PXC `Synced`, sem flow control,
`udp_rcvbuf_err` 0 e nenhuma resposta 4xx/5xx.

### 3.3 Degraus das metas

| | `stfc-meta-cps100` | `stfc-meta-c1000` | `stfc-meta-c2000` |
|---|---|---|---|
| Comando | `-r 100 --cps-start 10 --ramp-step 10 --ramp-interval 20 -H 10 -w 240` | `-r 10 -H 100 -w 150 -l 1100` | `-r 10 -H 200 -w 260 -l 2100` |
| Resultado | **Interrompido pelo guard** em 91 s (falha 60%) | **Sem limite atingido** | **Interrompido pelo guard** em 212 s (falha 48%) |
| Chamadas (sucesso/criadas) | 2263/2534 | 1515/1515 | 1967/2122 |
| Falhas | 271 (10,7%): 122 `503 No FreeSWITCH Available`, 27 `408`, 7 `480` | 0 | 155 (7,3%): 37 `503 No FreeSWITCH Available`, 18 `503 Maximum Calls In Progress`, 1 `480` |
| Pico de CPS | 50 | 10 | 10 |
| Pico de simultâneas | 716 | **1022** | **1962** |
| INVITE -> 200 (média) | **4615 ms** | **145 ms** | **140 ms** |
| CPU .163 (OpenSIPS + fs1), pico | 38,6% | 19,1% | 21,2% |
| CPU .162 (fs2), pico | 18,2% | 7,3% | 7,5% |
| CPU .161 (banco), pico | 30,8% | 21,2% | 28,2% (um núcleo a 100%) |
| `mysqld` .161, pico (100 = 1 núcleo) | 212 | 136 | 200 |
| Consultas/s .161 (média/pico) | 4514/6801 | 1961/2534 | 1781/2894 |
| Sessões no FS (pico .163 / .162) | 830 / 616 | 964 / 1064 | 1924 / **2000** |
| Diálogos / transações no OpenSIPS (pico) | 297 / 1018 | 1001 / 236 | 1962 / 117 |
| Memória compartilhada do OpenSIPS (pico) | **38,5%** | 18,9% | 21,7% |
| `os_failed_dlg` / `os_drop_req` | +212 / +154 | +0 / +0 | +123 / +104 |

No `stfc-meta-cps100`, a rampa passou de 40 para 50 CPS aos 60-80 s; a primeira amostra com falha
(12%) foi aos 81 s.

### 3.4 Atraso por FreeSWITCH (`pdd-pcap.py`)

"Ida": do INVITE do originador até o bridge chegar ao atendedor. "Volta": do 200 do atendedor
até o 200 chegar ao originador.

| Degrau | FS | Chamadas | Ida p50/p90 | Volta p50/p90 | Total p50/p90/máx |
|---|---|---|---|---|---|
| `stfc-cps25-pcap` | .163 | 745 | 74/88 ms | 23/43 ms | 103/123/175 ms |
| `stfc-cps25-pcap` | .162 | 831 | 121/441 ms | 77/1546 ms | 207/2049/5376 ms |
| `stfc-cps25-rede2` | .163 | 2384 | 72/364 ms | 42/1238 ms | 108/1768/7841 ms |
| `stfc-cps25-rede2` | .162 | 2162 | 792/2383 ms | 3589/9382 ms | **4743/11570/23929 ms** |

Total p90 por faixa de 20 s no `stfc-cps25-rede2`: 161 ms (3 CPS), 206 ms (15 CPS), 436 ms
(19 CPS), 1961 ms (23 CPS), 4,7 a 14 s (25 CPS sustentados, piorando com o tempo).

### 3.5 Tempos internos do FS .162 (captura no .163, `stfc-cps25-rede2`)

Medidos no .163 entre a mensagem enviada ao .162 e a resposta dele (rede de ~1 ms entre os dois):

| Faixa | Chamadas no .162 | INVITE reenviados | 200 reenviados | INVITE -> 100 p50 | INVITE -> INVITE da perna B p50 | 200 da perna B -> ACK p50 |
|---|---|---|---|---|---|---|
| 0-80 s (até 15 CPS) | 380 | 0 | 0 | 9-11 ms | 108-111 ms | 14-28 ms |
| 80-100 s (19 CPS) | 201 | 0 | 1 | 23 ms | 117 ms | 43 ms |
| 100-120 s (23 CPS) | 242 | 18 | 75 | 113 ms | 206 ms | 217 ms |
| 120-140 s (25 CPS) | 258 | 154 | 305 | 506 ms | 602 ms | 1189 ms |
| 180-200 s (25 CPS) | 275 | 396 | 614 | 1483 ms | 1493 ms | 4274 ms |
| 220-240 s (25 CPS) | 204 | 402 | 502 | 1802 ms | 1870 ms | 3614 ms |

Contagem completa: o .163 enviou 4031 INVITEs para 2163 chamadas (1868 retransmissões) e 7248
respostas 200 para ~4324 esperadas (~2924 retransmissões). O .162 recebeu 20.106 datagramas para
20.099 enviados pelo .163, sem descarte na interface, em `UdpInErrors` ou `RcvbufErrors`.

## 4. Achados

### A1. Atraso pós-discagem no sbc-stfc-02 (.162): fila de mensagens SIP no FreeSWITCH
- **Evidência:**
  - tabelas 3.4 e 3.5: até 15 CPS no sistema, o .162 responde 100 Trying em ~10 ms; a partir de ~20 CPS (cerca de 10 chamadas/s no .162), o tempo até o 100 Trying e até o ACK cresce continuamente, mesmo com a CPS constante;
  - o tempo de roteamento (do 100 Trying até o INVITE da perna B: dialplan Lua + banco) fica em ~100 ms do começo ao fim;
  - a CPU do FS do .162 fica baixa (média de 27%, pico de 0,6 núcleo): a thread que trata o SIP espera algo, não está saturada de processamento.
- **Descartado (com medição):**
  - rede e vSwitch: o .162 recebeu todos os datagramas enviados pelo .163, sem descarte na interface nem na pilha UDP; sem fragmentação;
  - firewall: a cadeia `defferrari` aceita `200.159.177.0/24` (inclui o .163 e o .165) antes da política `DROP`; os descartes da política (+531 em ~6,5 min) são de outras origens (varredura, A6);
  - banco do Flux e dialplan Lua (tempo de roteamento constante);
  - banco interno remoto: quem usa `core-db-dsn` no MySQL é o .163 (o nó rápido).
- **Diferenças de configuração entre os nós, suspeitas da causa:**
  - `sessions-per-second` 50 no .162 (300 no .163). `fs_cli status` mostrava pico de 48 de 50 no .162 e 55 no .163. Porém a coleta do flux-loadtest registrou 72 sessões/s no .162 no `stfc-meta-cps100`, o que enfraquece a hipótese de um teto rígido;
  - banco interno do FS: SQLite local (`/var/lib/freeswitch/db/core.db`) no .162 e MySQL (`core-db-dsn` FLUX) no .163;
  - `max-db-handles` 500 e `db-handle-timeout` 30 no .162 (50 e 10 no .163).
- **Impacto:** atinge as chamadas reais que o `load_balancer` envia ao .162 e limita o sistema a ~20 CPS com PDD aceitável.
- **Próximo passo (próxima janela):** repetir o degrau de 25 CPS por 240 s com `fsctl sps 300` no .162 (`fs-limites.sh aplicar 300 2000`, em runtime) e a captura no .163. Se não resolver, testar o banco interno do .162 em memória ou no MySQL (exige restart do FS).

### A2. Banco: ~240 consultas por chamada
- **Evidência:**
  - ~240 consultas por chamada, das quais ~37 UPDATE e ~6 INSERT;
  - a 50 CPS de pico (`stfc-meta-cps100`): 6,8 mil consultas/s, `mysqld` em 2,1 núcleos, CPU do .161 em 31% e 28 MB/s de escrita;
  - com 2000 simultâneas a 10 CPS, um núcleo do .161 chegou a 100% no pico.
- **Projeção revisada:** o banco não foi o limite até 50 CPS; a extrapolação linear coloca o guard de 75% acima de 100 CPS, mas ela precisa ser confirmada sem o A1.
- **Recomendação:** levantar no `performance_schema` (`events_statements_summary_by_digest`) quais consultas o dialplan Lua e o `xml_curl` repetem por chamada, e o que pode ir para cache.

### A3. Memória compartilhada do OpenSIPS (projeção anterior corrigida)
- **Evidência:**
  - com 1962 diálogos estáveis e 117 transações: 21,7% (de 5,8% em repouso), ~0,008% por diálogo;
  - com 297 diálogos, 275 em estabelecimento e 1018 transações (50 CPS com retransmissões): 38,5%.
- **Conclusão:** o consumo vem das transações em andamento (CPS x atraso), não dos diálogos. A projeção anterior (~0,04% por diálogo, estouro em ~2000) superestimava. 3000 simultâneas a CPS baixa ficariam em ~30%.
- **Risco que continua:** sob CPS alta com retransmissões, a memória sobe rápido. O guard do flux-loadtest não vigiava esse indicador na campanha; depois dela, passou a vigiar com `GUARD_MAX_OS_SHM_PCT`.
- **Recomendação:** aumentar o `-m` do OpenSIPS (ex.: 256 MB) antes de testar CPS acima de 50. Exige restart em janela própria.

### A4. CPU do sbc-stfc-1 (OpenSIPS e FS no mesmo servidor)
- **Evidência:** 38,6% de pico a 50 CPS (`freeswitch` até 2,1 núcleos, `opensips` até 0,17), contra 18% no .162.
- **Projeção revisada:** guard de 75% por volta de 100 CPS. Não foi o limite nesta campanha.

### A5. Configuração diferente entre os FreeSWITCH
`switch.conf`:

| FS | `sessions-per-second` | `max-sessions` | `max-db-handles` | `db-handle-timeout` | Banco interno |
|---|---|---|---|---|---|
| .163 | 300 | 2000 | 50 | 10 | MySQL (`core-db-dsn` FLUX) |
| .162 | 50 | 2000 | 500 | 30 | SQLite local |

- **Impacto:** o `load_balancer` distribui por carga e não sabe dessas diferenças; o .162 é o nó que atrasa (A1).
- **Recomendação:** igualar os dois nós depois de confirmar qual diferença causa o A1. Exige restart do FS.

### A6. Chamadas recusadas no sbc-stfc-02
O perfil `default` do .162 registra 104.440 chamadas de entrada desde o boot, 104.326 com falha
(99,9%). No .163 são 859, com 668 falhas. Os descartes da política `DROP` do firewall do .162
continuam durante os testes, vindos de fora das listas de origem. Tudo indica varredura SIP. O
`sps` 50 do .162 pode estar ali para conter isso; considerar antes de mudá-lo.

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
- **Rampa padrão:** com `-w` curto, o degrau não chega ao CPS alvo (3.2). Para medir um CPS, a janela precisa cobrir a rampa e pelo menos 2 minutos no alvo.

### A14. Teto de chamadas simultâneas: `max-sessions` 2000 por FS
- **Evidência (`stfc-meta-c2000`):** com 1962 simultâneas, o .162 chegou a 2000 sessões (`max-sessions`) e respondeu `503 Maximum Calls In Progress`; o .163 estava em 1924. Em seguida o `load_balancer` passou a responder `503 No FreeSWITCH Available`.
- **Conta:** 2 sessões por chamada -> 1000 chamadas por FS -> ~2000 no sistema, incluindo o tráfego real.
- **O resto aguentou:** INVITE -> 200 de 140 ms, memória do OpenSIPS em 21,7%, CPU do .163 em 21%, FS do .162 com 2,2 GB e 2024 threads.
- **Recomendação:**
  - para 3000 simultâneas: `max-sessions` de pelo menos 3500 por FS (`fsctl max_sessions` em runtime para testar; `switch.conf` para valer), e a capacidade do grupo 1 no `load_balancer` compatível (`lb_list` para conferir);
  - medir a memória e as threads do FS com 1500 chamadas por nó antes de fixar o valor.

### A15. `load_balancer` sem destino sob CPS alta
- **Evidência (`stfc-meta-cps100`):** 122 respostas `503 No FreeSWITCH Available` do OpenSIPS com só 716 simultâneas (830 e 616 sessões nos FS, longe de 2000), a 40-50 CPS; `os_failed_dlg` +212 e `os_drop_req` +154.
- **Hipótese:** com o atraso do A1, o .162 deixa de responder a tempo à sondagem do OpenSIPS (INFO na 5070) ou ao recurso `fs://`, e o `load_balancer` o tira de serviço; o tráfego vai todo para o .163, que esgota a capacidade configurada.
- **Próximo passo:** `opensips-cli -x mi lb_list` durante um degrau e o log do OpenSIPS (`lb`/`freeswitch`) no momento das falhas.

### A16. Interface web (.165) como maior cliente do banco
- **Evidência:** `performance_schema.events_statements_summary_by_host_by_event_name` no .161 (desde o boot): .165 com 470 milhões de comandos e 305 mil s de banco; .163 com 22,7 milhões; .162 com 20,4 milhões. `flux.mail_details` tem 66 milhões de INSERT.
- **Impacto:** a interface web e seus crons disputam o mesmo PXC das chamadas.
- **Recomendação:** revisar o cron que alimenta `mail_details` (crescimento e retenção) e as consultas da interface.

## 5. Capacidade

| Indicador | Medido | Limite atual | O que limita |
|---|---|---|---|
| CPS com PDD aceitável | ~20 CPS (total p90 de 436 ms a 19 CPS) | ~20 CPS | A1 (.162) |
| CPS máximo antes de falhar | 40-50 CPS (10,7% de falha, PDD médio de 4,6 s) | — | A1 + A15 |
| Chamadas simultâneas | 1022 sem falha; 1962 com falha no fim | ~2000 | A14 (`max-sessions`) |
| CPU do .163 | 38,6% a 50 CPS | ~100 CPS (projeção) | A4 |
| CPU do banco | 30,8% a 50 CPS | acima de 100 CPS (projeção) | A2 |
| Memória do OpenSIPS | 21,7% com 1962 diálogos; 38,5% a 50 CPS | CPS alta com retransmissão | A3 |

- **Metas de chamadas simultâneas:** 1000 atingida; 2000 no limite da configuração; 3000 exige `max-sessions` maior (A14).
- **Metas de CPS:** 100, 200 e 300 não atingidas. A ordem para avançar é: resolver o A1, rever o `load_balancer` (A15), aumentar o `-m` do OpenSIPS (A3) e só então medir de novo; com o A1 resolvido, a CPU do .163 e do banco projetam um teto perto de 100 CPS, ainda abaixo de 200.
- **Dimensionamento:** para 200 a 300 CPS serão necessários mais FS, o OpenSIPS em servidor próprio (hoje divide o .163 com o fs1) e menos consultas por chamada (A2).

## 6. Correções no repositório durante a campanha

| PR | Mudança |
|---|---|
| #6 | Runbook do teste completo (`deploy/stfc-completo/`) |
| #7 | Collation dos SQL, `fs-limites.sh` sem reduzir limites, preflight com `listen-ip` do event socket, limites reais dos FS no README |
| #8 | Atendedor devolve o `Record-Route` no 180 e no 200 |
| #9 | Criação de DIDs pelos índices (chave primária e `accountid`) |
| #10 | `pdd-pcap.py` |
| #11 | Este documento |
| #12 | Dashboard de resultados no Zabbix, execução e INVITE -> 200 no resultado de cada execução, `ZABBIX.md` e perfis do STFC |
| #13 | Include do `zabbix-agent` no diretório do `Include=` do agent (pacote do Debian) |
| #14 | Auditoria do agent sem abortar quando um include não tem a chave (`pipefail`) |
| #15 | Validação do agent sem `-T` (agent 6.0) |
| #16 | `dids-limpar.sh`, `95-dids-remove.sql` apontando para ele e sem varrer a tabela, documentação da integração com o Zabbix |

## 7. Integração com o Zabbix (22/10/2026)

Detalhes e reversão em `ZABBIX.md`.

| Item | Estado |
|---|---|
| Dashboard | `Flux Loadtest - Resultados (flt-)` no `zabbixnew.flux.net.br` (7.2.3): tabela com uma linha por execução, gráficos SIP e uma página por servidor |
| Execuções | As 9 de 21/10/2026 importadas, iguais aos `report.txt`. A `stfc-cps25-rede2` (degrau de 25 CPS por 240 s) entrou com 4546 chamadas, 0% de falha, INVITE -> 200 médio de 2659 ms e pico de 720 simultâneas: o teto do gerador (`25 x (20 + 4) x 1,2`), atingido porque o atraso do .162 (A1) acumulou chamadas |
| Envio ao vivo | Ativo: todo `run` do .165 aparece no dashboard |
| Disparo pelo menu | Host `flt-gen`, perfis `stfc-piloto`, `stfc-cps20` e `stfc-c1000`, restrito a `Zabbix administrators`. Primeiro uso: `stfc-cps20` em 22/10 02:57, parado pelo operador (código 6) |
| Alertas | Manutenção com coleta de dados nos hosts `flt-*` por 180 dias: nenhum problema do teste chega ao suporte |
| Testes antes da produção | Zabbix 7.2.3 local e uma VM de teste (Zabbix 7.0.32, com o template gerado por `gen_templates.py --version 7.0`) |

Achados:

- **A17. Ações de notificação sem condição.** As 5 ações do Zabbix de produção (e-mail e
  Telegram) valem para qualquer gatilho. Sem a manutenção, os gatilhos do guard chegariam ao
  suporte durante um teste. Definitivo: condição "tag `scope` diferente de `loadtest`".
- **A18. Templates do flux-loadtest em hosts reais.** `FreeSWITCH` e `OpenSIPS` em
  `SBC-STFC-162`/`SBC-STFC-163`; `Gerador` e `Execucao` em `SBC-STFC-INTERFACEWEB`. Não recebem
  dados nesses hosts: desvincular.
- **A19. Agent 6.0 do Debian no .165.** Diretório de include diferente do pacote oficial e sem
  `zabbix_agentd -T`: corrigidos no `prepare` (#13 a #15).

## 8. Pendências e decisões

1. **A1 (próxima janela):** degrau de 25 CPS por 240 s com `fs-limites.sh aplicar 300 2000` no .162 e captura no .163. Se não resolver, banco interno do .162 em memória ou no MySQL (restart do FS).
2. **A15:** `lb_list` e log do OpenSIPS durante um degrau acima de 25 CPS.
3. **A14:** degrau de 3000 simultâneas a 10 CPS com `fs-limites.sh aplicar 300 3500` nos dois FS, conferindo a capacidade do `load_balancer`.
4. **Decisões do responsável pelo ambiente (todas com restart):**
   - `-m` do OpenSIPS (A3);
   - igualar o `switch.conf` dos FS e o banco interno (A5);
   - nível de log do Lua (A7).
5. **Senha do event socket:** trocar nos dois FS e atualizar o `load_balancer` (A11).
6. **Banco:** investigar as ~240 consultas por chamada (A2) e o `mail_details` (A16).
7. **Zabbix:** desvincular os templates dos hosts reais (A18); decidir a condição de tag nas ações (A17) antes do fim da manutenção (20/04/2027); revogar os tokens de API usados nos testes.
8. **Ao fim da campanha:** reversão da seção 2 e da seção 8 do `README.md`. DIDs: `dids-limpar.sh contar` e `remover --conta 211` no .161; o DID modelo e a conta pela interface.
