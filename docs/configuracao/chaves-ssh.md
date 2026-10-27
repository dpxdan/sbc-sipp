# Chaves SSH

A ação `keys` cria a chave da VM, confia nas chaves de host dos servidores, instala a chave pública
restrita no `authorized_keys` do `SSH_USER`, testa e revoga.

## Caminho normal

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh keys setup --via admin --write-config -c /etc/flux-loadtest/loadtest.conf
```

`setup` = `create` + `trust` + `deploy` + `test`. Com `--write-config`, grava `SSH_KEY` e
`SSH_KNOWN_HOSTS` no `loadtest.conf` (com backup `.bak`).

Atrás de NAT (por exemplo, VM no Parallels), informe o IP público que os servidores enxergam:

```bash
curl -s https://ifconfig.me
```

```bash
./flux-loadtest.sh keys setup --from 203.0.113.50 --via admin --write-config
```

## Subcomandos

| Subcomando | O que faz |
|---|---|
| `create` | Gera `SSH_KEY` (0600, sem passphrase). Não sobrescreve uma chave existente: só mostra a impressão digital |
| `trust` | Lê as chaves de host com `ssh-keyscan`, mostra as impressões digitais e grava no `known_hosts` depois da confirmação |
| `deploy` | Instala a chave pública restrita à VM em cada servidor (pede senha) |
| `test` | Confirma o login por chave e se o `sudo -n` está disponível |
| `revoke` | Remove a chave do `authorized_keys` em todos os servidores (fim da campanha) |
| `setup` | `create` + `trust` + `deploy` + `test` |

| Opção | Descrição |
|---|---|
| `--key CAMINHO` | Sobrescreve `SSH_KEY` |
| `--type ed25519\|rsa` | Tipo da chave |
| `--comment TEXTO` | Comentário da chave |
| `--passphrase` | Pede passphrase (exige `ssh-agent` com a chave carregada no `run`) |
| `--from IPs` | `from=` do `authorized_keys` (IPs ou CIDR separados por vírgula) |
| `--via USUARIO` | Primeiro acesso com outro usuário + `sudo` (ex.: `admin`) |
| `--known-hosts ARQ` | `known_hosts` dedicado |
| `--write-config` | Grava `SSH_KEY` e `SSH_KNOWN_HOSTS` no `loadtest.conf` |
| `-y` | Não pede confirmação |

## Primeiro acesso do `deploy`

- **Sem `--via`:** pede a senha do próprio `SSH_USER`, como o `ssh-copy-id`.
- **Com `--via admin`:** entra como `admin` (senha ou chave dele) e usa `sudo` para gravar no
  `authorized_keys` do `SSH_USER`, ajustando dono e permissões. É o caminho quando o login por
  senha está bloqueado (`PermitRootLogin prohibit-password` é o padrão do Debian) e quando o
  usuário `loadtest` foi criado sem senha pelo `prepare`.

## Linha instalada em cada servidor

```
from="203.0.113.50",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc ssh-ed25519 AAAA... flux-loadtest@vm-20261007
```

Se a chave vazar, ela não funciona de outra origem e não abre terminal nem túnel. O script só
executa comandos sem terminal, então as restrições não o afetam. Rodar `deploy` de novo é seguro:
a linha é mantida ou tem as restrições atualizadas.

## Conferir e encerrar

```bash
./flux-loadtest.sh keys test
```

```bash
./flux-loadtest.sh keys revoke
```

| Sintoma | Causa | O que fazer |
|---|---|---|
| `keys test` falha depois de funcionar | O IP público mudou (NAT) | `keys deploy --from NOVO_IP` |
| SSH recusado depois do `deploy` por senha | fail2ban bloqueou por tentativas erradas | Whitelist do IP; conferir o jail do sshd |
