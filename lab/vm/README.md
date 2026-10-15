# Laboratório STFC em VMs Debian 12 (sem Docker)

Alternativa ao laboratório em Docker (`lab/lab.sh`) para quem tem VMs Debian 12:
o repositório fica só no **servidor de testes**, e o `lab/vm/vmlab.sh` instala e configura as
outras 5 VMs por SSH. Os papéis, os pacotes e a configuração são os mesmos do lab Docker
(mesmos modelos de `lab/images/`, mesmo seed do banco em `lab/lib/flux-db.sh`), com
serviços systemd no lugar dos processos dos containers.

| VM | Papel | Serviços |
|---|---|---|
| servidor de testes | flux-loadtest: SIPp originador e atendedor (DIDs DIRECT-IP), wrk, sysbench | — |
| `sbc-stfc-1` | OpenSIPS 3.6 + FreeSWITCH 1.11.3 com a stack Flux | `opensips`, `freeswitch`, `php7.3-fpm`, `nginx` (127.0.0.1:8735) |
| `sbc-stfc-02` | FreeSWITCH 1.11.3 com a stack Flux | `freeswitch`, `php7.3-fpm`, `nginx` |
| `banco-master-sbc-stfc` | Percona XtraDB Cluster 8.4.10 (nó 1) + keepalived (prioridade 150) | `mysql`, `keepalived` |
| `banco-slave-stfc` | Percona XtraDB Cluster 8.4.10 (nó 2) + keepalived (prioridade 100) | `mysql`, `keepalived` |
| `sbc-stfc-interfaceweb` | nginx + PHP-FPM 7.3 (página PHP com sessão no banco pelo VIP) | `nginx`, `php7.3-fpm` |

Zabbix: um servidor existente (7.2.3 em produção). O `vmlab.sh zabbix` só importa os
templates e cria os hosts; nada é instalado.

## Requisitos

- **VMs:** 6 VMs Debian 12 (bookworm), instalação mínima com `openssh-server`, IPs fixos e acesso à internet (repositórios Debian, Percona, SignalWire, OpenSIPS e sury).
- **Usuário administrador:** um usuário com sudo nas 5 VMs (`SSH_ADMIN_USER`, padrão `admin`). O `bootstrap` instala a chave do orquestrador e libera sudo sem senha para ele.
- **VIP:** um IP livre na rede interna para o VIP do banco (`DB_VIP`). O hypervisor precisa deixar passar o VRRP, que é unicast entre os dois bancos.
- **Uma interface por VM é suficiente:** use o mesmo IP como público e interno em `HOST_*`. Com duas interfaces, a face pública atende as operadoras e o RTP, e a interna atende cluster, VIP, event socket e devices, como no STFC.
- **Token da SignalWire:** em `SIGNALWIRE_TOKEN_FILE` (0600) no servidor de testes. Vai pelo stdin do SSH só na primeira instalação do FreeSWITCH e não fica gravado nas VMs.
- **Fork do Flux:** acessível pelo servidor de testes (`FLUX_GIT_URL`). Se o repositório for privado, use uma chave de deploy (somente leitura) em `/root/.ssh` com URL `git@...`, ou a credencial do git.
- **Scripts do `sbc01` (opcional):** os scripts Lua de produção, copiados para o servidor de testes (`FLUX_SCRIPTS_DIR`). Sem eles, valem os do clone.

Recursos sugeridos (laboratório; para medir capacidade, use o dimensionamento do README
principal):

| VM | vCPU | Memória | Disco |
|---|---|---|---|
| servidor de testes | 4 | 4 GB | 20 GB |
| `sbc-stfc-1`, `sbc-stfc-02` | 2 | 2 GB | 20 GB |
| bancos | 2 | 4 GB | 30 GB |
| interfaceweb | 1 | 1 GB | 10 GB |

Portas entre as VMs (sem firewall no Debian mínimo; libere se houver):

| Origem → destino | Portas |
|---|---|
| servidor de testes → sbc-stfc-1 | 5060/udp (SIP) e RTP dos FS |
| sbc-stfc-1/02 → servidor de testes | `UAS_PORT`/udp (atendedor) e RTP a partir de 40000/udp |
| servidor de testes ↔ RTP dos FS | `RTP_START`-`RTP_END`/udp (padrão 16384-32768) |
| servidor de testes → todas | 22/tcp (SSH do vmlab e do flux-loadtest) |
| sbc-stfc-1 → sbc-stfc-1/02 | 5070/udp, 5080/udp, 8021/tcp (event socket) |
| SBC e web → VIP | 3306/tcp |
| banco ↔ banco | 3306, 4444, 4567, 4568/tcp e VRRP (protocolo 112) |

## Passo a passo

No servidor de testes, como root:

```bash
apt-get update && apt-get install -y git
```

```bash
git clone https://github.com/dpxdan/sbc-sipp.git /opt/flux-loadtest
```

```bash
cd /opt/flux-loadtest/lab/vm
```

Na primeira vez, o `init` só cria o `vmlab.conf` a partir do exemplo:

```bash
./vmlab.sh init
```

Ajuste o `vmlab.conf`: `GEN_IP`, `HOST_*`, `DB_VIP`, `NET_PATTERN`, `FLUX_GIT_URL` e, se
houver, o Zabbix. Depois rode o `init` de novo, que gera as senhas e a chave do orquestrador
em `STATE_DIR`:

```bash
./vmlab.sh init
```

Grave o token da SignalWire (substitua o texto antes de rodar):

```bash
install -d -m 0700 /root/.config/flux-lab && (umask 077 && printf '%s\n' 'COLE_O_TOKEN' > /root/.config/flux-lab/signalwire.token)
```

Confira as chaves de host com o console de cada VM e instale a chave do orquestrador (pede
a senha do `SSH_ADMIN_USER` e, se preciso, a do sudo):

```bash
./vmlab.sh bootstrap
```

Instalação completa (alguns minutos por VM na primeira vez):

```bash
./vmlab.sh up
```

O `up` executa, nesta ordem:
1. **`gen`:** pacotes e limites do servidor de testes.
2. **`flux-src`:** clona ou atualiza o fork.
3. **`common`:** pacotes base, `/etc/hosts`, relógio e usuário `loadtest`.
4. **`db`:** bootstrap no nó 1, SST no nó 2 e keepalived; o nó 1 volta a membro comum.
5. **`flux`:** schema e dados do laboratório.
6. **`web`.**
7. **`sbc`:** primeiro o `sbc-stfc-02`, depois o `sbc-stfc-1`. O OpenSIPS sobe depois do FS.
8. **`conf`:** `/etc/flux-loadtest/loadtest.conf`.
9. **`keys`:** chaves SSH do flux-loadtest.
10. **`zabbix`.**
11. **`smoke`:** `check` e uma chamada para um DID DIRECT-IP.

Cada etapa pode ser repetida sozinha, e todas são idempotentes. Os logs de cada papel ficam em
`STATE_DIR/logs`.

Teste de carga, depois do `up`:

```bash
/opt/flux-loadtest/flux-loadtest.sh run -c /etc/flux-loadtest/loadtest.conf --confirm-prod -t sip -r 10 -H 20 -w 120 --label vm-cps10
```

Estado das VMs (serviços, cluster, VIP, perfis SIP):

```bash
./vmlab.sh status
```

## O que é gravado em cada VM

| Caminho | Conteúdo |
|---|---|
| `/opt/flux-lab` | Papéis (`vm/roles`) e modelos (`images/db`, `images/web`, `images/sbc-real`) enviados pelo vmlab |
| `/etc/flux-lab/role.env` | Variáveis e senhas do papel daquela VM (0600) |
| `/opt/flux-src`, `/opt/flux-scripts` | SBC: `freeswitch/`, `config/` e `web_interface/nginx` do fork; scripts Lua de produção |
| `/etc/sudoers.d/90-flux-lab-admin` | sudo sem senha para o `SSH_ADMIN_USER` (só se o sudo pedia senha) |
| `/etc/sudoers.d/flux-loadtest` | SBC: `loadtest` pode rodar `fs_cli` e `opensips-cli` (coleta) |
| `/etc/mysql/flux-loadtest.cnf` | Bancos: credencial somente leitura da coleta (0600, dono `loadtest`) |
| `/etc/systemd/system/freeswitch.service`, `/etc/default/opensips`, `opensips.service.d/flux-lab.conf` | FreeSWITCH como root (igual ao container; os pacotes da SignalWire não trazem unidade) e OpenSIPS em primeiro plano, com log no journal |

Na primeira execução do papel `db`, o datadir do nó é recriado. O papel recusa a operação se
já existir o schema `flux` nele, para não apagar dados que não sejam do laboratório.

## Diferenças em relação ao lab Docker

| Item | Docker | VMs |
|---|---|---|
| Processos | Iniciados direto pelo `start.sh` | Unidades systemd dos pacotes (`LAB_INIT=systemd` no mesmo `start.sh`) |
| Root do MySQL | Senha do `.env` | `auth_socket` (o vmlab usa `sudo mysql` no nó 1) |
| Perfil dos devices (id 100, 5080) | `lab-mac`, mídia anunciada em 127.0.0.1 (portas publicadas no macOS) | `lab-dev`, mídia no IP interno da VM; o device registra direto no OpenSIPS `IP:5060` |
| Sockets 5062 do OpenSIPS | Para o macOS | Não existem |
| Zabbix | Containers 7.2.3 + PostgreSQL 16 | Servidor existente |
| Reinício | `lab.sh up` recria tudo | Os serviços sobem no boot. Com os dois bancos parados, o bootstrap é manual no nó com `safe_to_bootstrap: 1` |

## Validação (2026-10-15)

Feita com 6 containers Debian 12 com systemd (`jrei/systemd-debian:12`, privilegiados) numa
rede própria, uma interface por "VM" (IP público = interno). O `vmlab.sh` rodou de dentro do
"servidor de testes", com o fork clonado de um caminho local e os scripts do `sbc01`.

| Etapa | Resultado |
|---|---|
| `init`, `bootstrap -y` | Senhas e chave geradas; chaves de host gravadas, SSH por chave e `sudo -n` nas 5 VMs (a chave pública e o sudo foram pré-instalados: o `ssh-copy-id` pede senha) |
| `gen`, `flux-src`, `common` | Pacotes, `git clone`, hostname e `/etc/hosts` nas 5 VMs |
| `db` | PXC 8.4.10: bootstrap no nó 1, SST no nó 2 (`Synced`), nó 1 de volta a membro comum, keepalived com o VIP no nó 1. Segunda execução: nada recriado, 100 mil DIDs intactos |
| `flux` | 158 tabelas, 0 erros; `did_call_types` 7 e 8 corretos (ver abaixo) |
| `web`, `sbc` | nginx 1.22.1 + PHP-FPM 7.3.33; FreeSWITCH 1.11.3 (perfis `default` 5070 e `lab-dev` 5080) nos dois SBC; OpenSIPS 3.6.9 no `sbc-stfc-1` |
| `conf`, `keys`, `smoke` | `check` com os dois FS `ready` e o `load_balancer` nos dois nós; `smoke` 1/1, chamada recebida pelo atendedor |
| `run -t sip -r 2 -H 10 -w 40` | 71/71 no originador e no atendedor, nenhum limite atingido |
| `run -t sip,web -r 3 -H 15 -w 45` | 83/83 chamadas sem falha; interrompido pelo guard por CPU (os 6 containers dividem as 4 vCPUs da VM do Docker) |

Ajustes que a validação trouxe (valem também para o lab Docker):
- **Ordem das migrações (`database/updates`):** passou a usar só o nome do arquivo. Com um `-` no caminho do clone (ex.: `/opt/flux-src`), o `sort` ordenava por mês e dia, sem o ano.
- **Auto_increment na carga do schema:** num PXC de 2 nós, o Galera usa `auto_increment_increment=2` e um offset por nó, e ignora `SET SESSION`. O id gerado pelo `ringgroup_1.0.0.sql` (7) virava 8 e colidia com o `update-12-06-2025.sql`. Durante a carga, `wsrep_auto_increment_control` fica desligado com sequência 1/1, e os valores são restaurados no fim. Uma instalação do Flux direto num PXC tem o mesmo risco.
- **Unidade do FreeSWITCH:** os pacotes da SignalWire não trazem unidade systemd; o `start.sh` cria `/etc/systemd/system/freeswitch.service`.

## Limitações

- Falta validar em VMs reais: VRRP entre hosts, firewall, duas interfaces por VM e o
  `ssh-copy-id`/sudo com senha do `bootstrap`.
- O `vmlab.sh` não remove o que instalou. Para recomeçar, recrie as VMs ou apague
  `/etc/flux-lab/db-initialized` e o datadir nos bancos.
