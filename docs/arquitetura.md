# Arquitetura

## Visão geral

```
VM de teste --INVITE:5060--> OpenSIPS (sbc-stfc-1) --load_balancer--> FS1 :5070 (sbc-stfc-1)
     |                                                          \--> FS2 :5070 (sbc-stfc-02)
     |<--INVITE:5090 + RTP do FS (DIDs DIRECT-IP, atendedor)            |
     |--wrk--> nginx -> PHP-FPM 7.3 (sbc-stfc-interfaceweb)             v
     |                         \------------------------> VIP 172.17.4.100 (keepalived)
     |--sysbench (opcional, rede interna) --------------->   Percona XtraDB Cluster
     |                                                       banco-master <-wsrep-> banco-slave
     +--ssh (coletor /proc) --> todos os servidores
```

| Carga | Ferramenta | O que mede |
|---|---|---|
| SIP | SIPp originador + SIPp atendedor | OpenSIPS, `load_balancer`, dialplan Lua, consulta do DID no MySQL, billing, bridge e, com RTP, mídia nos dois sentidos |
| Web | `wrk` | Arquivo estático (só nginx) e página PHP (nginx + PHP-FPM + sessão no MySQL) |
| MySQL | `sysbench oltp_read_write` | Cluster PXC pelo VIP, em schema isolado (`loadtest`) |
| Monitoramento | `lib/collector.sh` | Coleta passiva em todos os servidores e na própria VM, a cada `SAMPLE_INTERVAL` (5 s) |

## Caminho de uma chamada de teste

É o mesmo caminho de uma chamada real de operadora para um DID:

```
SIPp originador :5060 --INVITE--> OpenSIPS :5060 (tabela address, grupo 10 = operadoras)
  --> load_balancer grupo 1 --> FS .163:5070 ou FS .162:5070
        dialplan Lua: consulta o DID no MySQL pelo VIP, billing
  --> bridge DIRECT-IP (sai pelo OpenSIPS, record_route) --> SIPp atendedor :5090
```

!!! note "Duas sessões por chamada"
    Cada chamada de teste abre **2 sessões** no FreeSWITCH que a atende: a perna A (entrada) e a
    perna B (bridge para o atendedor). Esse fator aparece em toda conta de capacidade:
    `max-sessions`, `sessions-per-second` e portas RTP.

Por que DIDs DIRECT-IP apontando para a própria VM:

- o FS faz `bridge sofia/<perfil>/<DID>@<extensions>`, e com `extensions = IP:porta` da VM a
  chamada volta para o atendedor (`UAS_PORT`);
- o atendedor responde 200 OK com SDP e, com `--media rtp`, também transmite;
- assim o teste mede sinalização, banco, billing e mídia sem gerar chamadas para clientes.

Detalhes em [Conta e DIDs de teste](instalacao/massa-dids.md).

## Ambiente STFC

Todos os servidores rodam **Debian 12**.

| Servidor | IP público | IP interno | Função | Versões e portas |
|---|---|---|---|---|
| `sbc-stfc-1` | 200.159.177.163 | 172.17.4.163 | OpenSIPS + FreeSWITCH 1 | OpenSIPS 3.6.8 (SIP 5060); FreeSWITCH 1.11.3 (SIP 5070) |
| `sbc-stfc-02` | 200.159.177.162 | 172.17.4.162 | FreeSWITCH 2 | FreeSWITCH 1.11.3 (SIP 5070) |
| `banco-master-sbc-stfc` | 200.159.177.161 | 172.17.4.161 | Banco (nó 1) | Percona XtraDB Cluster 8.4.10, WSREP 26.1.4.3 |
| `banco-slave-stfc` | 200.159.177.164 | 172.17.4.164 | Banco (nó 2) | Percona XtraDB Cluster 8.4.10, WSREP 26.1.4.3 |
| `sbc-stfc-interfaceweb` | 200.159.177.165 | 172.17.4.165 | Interface web (e gerador na campanha) | nginx 1.22.1; PHP-FPM 7.3.33 |
| VIP do banco | — | 172.17.4.100 | Endereço do MySQL para os servidores | keepalived |

Consequências para o teste:

- **OpenSIPS e FS1 no mesmo servidor.** O `.163` aparece duas vezes na configuração
  (`OPENSIPS_HOST` e `FS_HOSTS`). As métricas de sistema se repetem em `opensips` e `fs1`; as de
  serviço são separadas. A CPU do servidor é a soma dos dois serviços.
- **Banco em Galera, não em réplica assíncrona.** O `SHOW REPLICA STATUS` fica vazio; o que importa
  é o estado do cluster (Synced, Primary, flow control). Com dois nós e sem árbitro (`garbd`), a
  queda abrupta de um nó tira o quórum do outro.
- **VIP só na rede interna.** A coleta no banco funciona de qualquer lugar (roda no próprio
  servidor), mas `--tests mysql` exige uma VM de teste na rede 172.17.4.0/24.
- **VM de teste fora da rede interna** usa os IPs públicos, sai por NAT e precisa ter o IP
  público liberado.
- **Gerador no `.165`.** Na campanha, o gerador rodou no servidor da interface web: os dois
  dividem CPU, por isso o guard do gerador é mais baixo no runbook.

## Papéis no `loadtest.conf`

Cada servidor configurado vira um identificador usado em todos os arquivos de saída:

| Chave | Identificador |
|---|---|
| `OPENSIPS_HOST` | `opensips` |
| `FS_HOSTS` (lista) | `fs1`, `fs2`, ... |
| `DB_HOSTS` (lista) | `db1`, `db2`, ... |
| `WEB_HOST` | `web` |
| (a própria VM) | `gen` |

Servidor com chave vazia fica fora do teste. Para testar só um FreeSWITCH, preencha apenas
`FS_HOSTS` (veja [FreeSWITCH direto](execucao/fs-direto.md)).
