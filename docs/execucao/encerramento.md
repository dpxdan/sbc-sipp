# Encerramento e reversão

Execute ao fim da janela ou ao abortar, nesta ordem.

## 1. Limites do FreeSWITCH

Em cada FS:

```bash
bash /opt/flux-loadtest/deploy/stfc-completo/fs-limites.sh restaurar
```

## 2. Liberação no OpenSIPS

No nó 1 do banco:

```bash
mysql flux < /opt/flux-loadtest/deploy/stfc-completo/sql/90-opensips-address-remove.sql
```

No `.163`:

```bash
opensips-cli -x mi address_reload
```

Para teste direto no FS, reverta a `acl_lb_networks` (veja [FreeSWITCH direto](fs-direto.md)).

## 3. DIDs de teste

No `.161` (nó 1 do banco). Primeiro a contagem, que não altera nada:

```bash
cd /opt/flux-loadtest && git pull --ff-only && bash deploy/stfc-completo/dids-limpar.sh contar --conta 211
```

Depois a remoção. Ela pede para digitar `REMOVER`, apaga em lotes de 5.000 pela chave primária com
1 s entre os lotes (o PXC replica sem flow control) e mostra a contagem no fim:

```bash
bash deploy/stfc-completo/dids-limpar.sh remover --conta 211
```

- Entram só os DIDs da conta informada, na faixa `5500000xxxxxx`, DIRECT-IP para
  `200.159.177.165:5090`. Qualquer outro DID aparece na contagem e fica.
- O DID modelo `5500000000000` fica: remova pela interface, para o produto dele sair junto
  (`--incluir-modelo` remove pelo banco e deixa o produto órfão).
- Os CDRs das chamadas de teste ficam, como histórico da conta de teste.

Depois, remova o DID modelo e desative a conta de teste pela interface.

## 4. Chaves SSH

```bash
cd /opt/flux-loadtest && ./flux-loadtest.sh keys revoke -c /etc/flux-loadtest/loadtest.conf
```

## 5. Rede

Desfaça as liberações de firewall, fail2ban e Event Guard do gerador. A regra temporária dos SBC:

```bash
iptables -D INPUT -s 200.159.177.165/32 -p udp -m comment --comment flux-loadtest -j ACCEPT
```

## 6. Resultados e arquivos de diagnóstico

- Guarde os pacotes `/var/lib/flux-loadtest/results/*.tar.gz` para a análise.
- Apague as capturas SIP (`*.pcap`) e os arquivos de diagnóstico em `/root` depois da análise: eles
  contêm DIDs e cabeçalhos SIP.

## Zabbix

Pode ficar, se as próximas campanhas forem usar.

| Item | Como desfazer |
|---|---|
| Envio ao vivo | Esvaziar `ZABBIX_SERVER` no `loadtest.conf` |
| Agent do gerador | Remover o include `flux-loadtest.conf` do diretório do `Include=`, `/etc/sudoers.d/flux-loadtest-zbx`, `/usr/local/sbin/flux-loadtest-zbx` e `/etc/flux-loadtest/profiles.d/`; reiniciar o `zabbix-agent` |
| Hosts, templates, scripts e dashboard | Excluir o grupo `Flux Loadtest` e seus hosts, os templates de `Templates/Flux Loadtest`, os scripts do menu `Flux Loadtest` e o dashboard |
| Manutenção | Excluir `Flux Loadtest - sem alertas ao suporte` |
| Token | Revogar em *Users > API tokens* e apagar `/etc/flux-loadtest/zabbix_api.token` |

## O que pode ficar

| Item | Observação |
|---|---|
| Usuário `loadtest` e `flux_monitor` | Úteis para próximas campanhas; remova com `userdel -r loadtest` e `DROP USER 'flux_monitor'@'localhost'` |
| Pacotes, sysctl e limits do gerador | `apt purge sip-tester wrk sysbench` e remover os arquivos `90-flux-loadtest.conf` se não forem mais usados |
| `/root/.fs_cli_conf` | Uso do root; remova se não for desejado |

Os backups de cada `prepare` ficam em `/var/backups/flux-loadtest/<data>/` no servidor onde ele
rodou.
