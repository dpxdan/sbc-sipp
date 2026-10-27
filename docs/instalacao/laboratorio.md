# Laboratório

Réplica do ambiente STFC para validar o flux-loadtest, os cenários e a integração com o Zabbix sem
tocar na produção. Existem três formas de montá-lo:

| Forma | Onde roda | Quando usar | Documento |
|---|---|---|---|
| Docker (`lab/lab.sh`) | Uma máquina com Docker (ex.: macOS com Docker Desktop) | Validar mudanças no script, cenários e templates; registrar softphones pelo macOS | [`lab/README.md`](https://github.com/dpxdan/sbc-sipp/blob/master/lab/README.md) |
| VMs orquestradas (`lab/vm/vmlab.sh`) | 6 VMs Debian 12; o script roda no servidor de testes e configura as outras 5 por SSH | Lab mais próximo da produção, com systemd | [`lab/vm/README.md`](https://github.com/dpxdan/sbc-sipp/blob/master/lab/vm/README.md) |
| Instalador local (`install/flux-host.sh lab`) | Em cada VM, sem orquestrador | Quando o SSH entre as VMs não é possível ou desejado | [`install/README.md`](https://github.com/dpxdan/sbc-sipp/blob/master/install/README.md) |

As três usam os mesmos papéis (`lab/vm/roles`), o mesmo inventário (`lab/lib/inventory.sh`) e o
mesmo seed do banco (`lab/lib/flux-db.sh`).

!!! danger "Só em servidores novos"
    O modo `lab` recria o datadir do MySQL na primeira execução e recusa se já existir o schema
    `flux`. Nunca use `lab` em servidores com dados: nos servidores existentes, use `prepare`.

## O que o laboratório reproduz

| Componente | Laboratório |
|---|---|
| OpenSIPS | 3.6, com `address` grupo 10 = VM de teste e `load_balancer` grupo 1 para os dois FS |
| FreeSWITCH | 1.11.3 com a stack Flux real (PHP do `xml_curl`, dialplan Lua, ODBC) |
| Banco | Percona XtraDB Cluster 8.4.10 + keepalived (VIP) |
| Web | nginx 1.22.1 + PHP-FPM 7.3.33, página PHP com sessão no banco pelo VIP |
| Zabbix | 7.2.3, mesma versão da produção (no Docker; nas VMs, um Zabbix existente) |
| Massa | Conta de teste e 100 mil DIDs DIRECT-IP para o atendedor da VM de teste |

No Docker, a rede interna é 172.30.4.0/24 e a "pública" 172.30.177.0/24, com os mesmos finais de
IP da produção. Como uma VM fora da rede interna, a `vm-teste` não alcança o VIP: para testar o
sysbench, ligue-a à rede interna com `./lab.sh interna`.

Sem o token da SignalWire e o repositório `sbc`, `LAB_SBC_TARGET=sbc` sobe um SBC simulado com
SIPp, suficiente para validar o script.

## Lab Docker em quatro comandos

```bash
cd lab && ./lab.sh up
```

```bash
./lab.sh status
```

```bash
./lab.sh keys
```

```bash
./lab.sh shell
```

Dentro da `vm-teste`, o repositório está montado em `/opt/flux-loadtest` e o `loadtest.conf` em
`/etc/flux-loadtest/loadtest.conf`:

```bash
./flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -y -t sip,web,mysql -r 10 -H 10 -w 120 --web-duration 20 --mysql-duration 30 --label lab-todos
```

## Lab em VMs

No servidor de testes, como root:

```bash
cd /opt/flux-loadtest/lab/vm && ./vmlab.sh init
```

Ajuste o `vmlab.conf` gerado e rode o `init` de novo. Depois:

```bash
./vmlab.sh bootstrap
```

```bash
./vmlab.sh up
```

```bash
./vmlab.sh status
```

## Limites do que o laboratório prova

- Valida funcionamento, não capacidade: os recursos das VMs são menores que os da produção.
- No laboratório, o FS faz o bridge direto para o atendedor. Em produção, a perna B sai pelo
  OpenSIPS (`record_route`): foi assim que o achado A8 (atendedor sem `Record-Route`) só apareceu
  em produção.
- O tráfego real, o Event Guard e o firewall de produção não existem no laboratório.
